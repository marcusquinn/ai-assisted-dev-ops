#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Provider-neutral marketing performance ingest contract."""

from __future__ import annotations

import json
import math
import re
from copy import deepcopy
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Any

SCHEMA_VERSION = 1
SOURCE_KINDS = {
    "campaign",
    "phase1",
    "social",
    "analytics",
    "crm",
    "commerce",
    "outreach",
    "normalized",
}
EVENT_TYPES = {
    "impression",
    "engagement",
    "follower",
    "subscriber",
    "social_receipt",
    "visit",
    "conversion",
    "lead_created",
    "lead_stage",
    "sale",
    "revenue",
    "refund",
    "cost",
    "outreach_sent",
    "outreach_reply",
    "outreach_bounce",
    "unsubscribe",
    "correction",
}
SUBJECT_KINDS = {"aggregate", "anonymous", "lead", "contact", "account", "audience"}
IDENTITY_STATES = {"not_applicable", "isolated", "linked", "split", "ambiguous"}
UNITS = {
    "impression",
    "engagement",
    "follower",
    "subscriber",
    "receipt",
    "visit",
    "conversion",
    "lead",
    "sale",
    "refund",
    "currency",
    "message",
    "reply",
    "bounce",
    "unsubscribe",
    "ratio",
}
AGGREGATIONS = {"sum", "average", "latest", "none"}
CONFIDENCE = {"low", "medium", "high", "verified"}
COMPLETENESS = {"complete", "partial", "unknown"}
SOURCE_TYPES = {
    "manual",
    "api_export",
    "csv_export",
    "derived",
    "fixture",
    "agent_estimate",
    "external_report",
}
ALIAS_RE = re.compile(r"^[a-z0-9][a-z0-9._:-]{0,127}$")
METRIC_RE = re.compile(r"^marketing\.[a-z0-9_]+(?:\.[a-z0-9_]+)+$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
TIMESTAMP_RE = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]{1,6})?Z$"
)
DIMENSION_KEY_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
PUBLIC_DIMENSION_KEYS = frozenset(
    {
        "audience",
        "case_type",
        "cohort",
        "environment",
        "experiment_variant",
        "priority",
        "project_phase",
        "region",
    }
)
RESERVED_DIMENSION_KEYS = frozenset(
    {"channel", "creative_id", "touchpoint_id", "outcome_id", "currency"}
)
DIRECT_DIMENSION_KEY_RE = re.compile(
    r"(?:^|_)(?:address|credential|destination|email|first_name|full_name|"
    r"last_name|name|password|payload|phone|secret|token)(?:_|$)"
)
DIRECT_DIMENSION_VALUE_RE = re.compile(
    r"(?:[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}|"
    r"https?://|mailto:|tel:|\b[0-9]{10,15}\b|\+[0-9 ()-]{9,})",
    re.IGNORECASE,
)
PHONE_CANDIDATE_RE = re.compile(r"\+?[0-9][0-9 /()._:-]{8,}[0-9]")
VANITY_PHONE_RE = re.compile(
    r"\b(?:1[-. /_:]?)?(?:800|833|844|855|866|877|888)"
    r"[-. /_:]?[a-z0-9]{7,}\b",
    re.IGNORECASE,
)
MAX_SAFE_JSON_INTEGER = 9_007_199_254_740_991

METRIC_DEFINITIONS: dict[str, tuple[str, str, str]] = {
    "marketing.impressions.total": ("Impressions", "count", "Observed content impressions"),
    "marketing.engagement.total": ("Engagements", "count", "Observed engagement actions"),
    "marketing.followers.total": ("Followers", "count", "Observed follower count or change"),
    "marketing.subscribers.total": ("Subscribers", "count", "Observed subscriber count or change"),
    "marketing.social.receipts.succeeded": ("Successful social receipts", "count", "Content-free successful social provider receipts"),
    "marketing.visits.total": ("Visits", "count", "Observed site or campaign visits"),
    "marketing.clicks.total": ("Clicks", "count", "Observed campaign link clicks"),
    "marketing.clicks.rate": ("Click-through rate", "ratio", "Clicks divided by impressions"),
    "marketing.conversions.total": ("Conversions", "count", "Observed conversion outcomes"),
    "marketing.leads.created": ("Leads created", "count", "New source-observed leads"),
    "marketing.leads.qualified": ("Qualified leads", "count", "Leads accepted as qualified"),
    "marketing.sales.total": ("Sales", "count", "Completed sale outcomes"),
    "marketing.refunds.total": ("Refunds", "count", "Completed refund outcomes"),
    "marketing.revenue.gross": ("Gross revenue", "currency", "Gross source-observed revenue"),
    "marketing.revenue.refunded": ("Refunded revenue", "currency", "Source-observed refunded amount"),
    "marketing.cost.amount": ("Marketing cost", "currency", "Source-observed marketing cost"),
    "marketing.return_on_investment.ratio": ("Return on investment", "ratio", "Revenue return relative to cost"),
    "marketing.outreach.sent": ("Outreach sent", "count", "Outreach messages reported sent"),
    "marketing.outreach.replies": ("Outreach replies", "count", "Replies attributed to outreach"),
    "marketing.outreach.bounces": ("Outreach bounces", "count", "Outreach delivery bounces"),
    "marketing.outreach.unsubscribes": ("Outreach unsubscribes", "count", "Outreach unsubscribe outcomes"),
}

METRIC_CONTRACTS: dict[str, tuple[set[str], str, set[str]]] = {
    "marketing.impressions.total": ({"impression"}, "impression", {"sum"}),
    "marketing.engagement.total": ({"engagement"}, "engagement", {"sum"}),
    "marketing.followers.total": ({"follower"}, "follower", {"sum", "latest"}),
    "marketing.subscribers.total": ({"subscriber"}, "subscriber", {"sum", "latest"}),
    "marketing.social.receipts.succeeded": ({"social_receipt"}, "receipt", {"sum"}),
    "marketing.visits.total": ({"visit"}, "visit", {"sum"}),
    "marketing.clicks.total": ({"engagement"}, "engagement", {"sum"}),
    "marketing.clicks.rate": ({"engagement"}, "ratio", {"average", "latest", "none"}),
    "marketing.conversions.total": ({"conversion"}, "conversion", {"sum"}),
    "marketing.leads.created": ({"lead_created"}, "lead", {"sum"}),
    "marketing.leads.qualified": ({"lead_stage"}, "lead", {"sum"}),
    "marketing.sales.total": ({"sale"}, "sale", {"sum"}),
    "marketing.refunds.total": ({"refund"}, "refund", {"sum"}),
    "marketing.revenue.gross": ({"revenue"}, "currency", {"sum"}),
    "marketing.revenue.refunded": ({"refund"}, "currency", {"sum"}),
    "marketing.cost.amount": ({"cost"}, "currency", {"sum"}),
    "marketing.return_on_investment.ratio": (
        {"conversion", "engagement"},
        "ratio",
        {"average", "latest", "none"},
    ),
    "marketing.outreach.sent": ({"outreach_sent"}, "message", {"sum"}),
    "marketing.outreach.replies": ({"outreach_reply"}, "reply", {"sum"}),
    "marketing.outreach.bounces": ({"outreach_bounce"}, "bounce", {"sum"}),
    "marketing.outreach.unsubscribes": ({"unsubscribe"}, "unsubscribe", {"sum"}),
}


class PerformanceContractError(ValueError):
    """Raised when an ingest contract cannot be normalized safely."""


def utc_now() -> str:
    """Return a canonical UTC timestamp."""
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_timestamp(value: Any, field: str) -> str:
    """Validate and canonicalize one RFC3339 UTC timestamp."""
    if not isinstance(value, str) or not TIMESTAMP_RE.fullmatch(value):
        raise PerformanceContractError(f"{field} must be an RFC3339 UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise PerformanceContractError(f"{field} must be an RFC3339 UTC timestamp") from exc
    if parsed.tzinfo is None or parsed.utcoffset() != timezone.utc.utcoffset(parsed):
        raise PerformanceContractError(f"{field} must use UTC")
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def timestamp_epoch(value: str) -> float:
    """Convert a validated timestamp to a UTC epoch."""
    return datetime.fromisoformat(value[:-1] + "+00:00").timestamp()


def contains_direct_identifier(value: str) -> bool:
    """Detect contact destinations in bounded values intended for public output."""
    if DIRECT_DIMENSION_VALUE_RE.search(value) or VANITY_PHONE_RE.search(value):
        return True
    for candidate in PHONE_CANDIDATE_RE.findall(value):
        digit_count = len(re.sub(r"[^0-9]", "", candidate))
        if 10 <= digit_count <= 15:
            return True
    return False


def require_alias(value: Any, field: str) -> str:
    """Require a bounded local alias safe for normalized output and paths."""
    if (
        not isinstance(value, str)
        or not ALIAS_RE.fullmatch(value)
        or contains_direct_identifier(value)
    ):
        raise PerformanceContractError(f"{field} must be a bounded lowercase alias")
    return value


def require_private_ref(value: Any, field: str) -> str:
    """Require an in-memory source reference that will be HMAC-pseudonymized."""
    if not isinstance(value, str) or not value or len(value) > 512 or CONTROL_RE.search(value):
        raise PerformanceContractError(f"{field} must be a bounded source reference")
    return value


def optional_alias(value: Any, field: str) -> str | None:
    """Normalize one optional safe alias."""
    if value is None:
        return None
    return require_alias(value, field)


def decimal_text(value: Any, field: str) -> str:
    """Return a finite canonical decimal string without exponent notation."""
    if isinstance(value, bool):
        raise PerformanceContractError(f"{field} must be numeric")
    try:
        number = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise PerformanceContractError(f"{field} must be numeric") from exc
    if not number.is_finite() or (isinstance(value, float) and not math.isfinite(value)):
        raise PerformanceContractError(f"{field} must be finite")
    digits = number.as_tuple().digits
    if len(digits) > 128 or (number and abs(number.adjusted()) > 128):
        raise PerformanceContractError(f"{field} exceeds the decimal precision limit")
    normalized = format(number, "f")
    if "." in normalized:
        normalized = normalized.rstrip("0").rstrip(".")
    normalized = "0" if normalized in {"-0", ""} else normalized
    if len(normalized) > 128:
        raise PerformanceContractError(f"{field} exceeds the decimal precision limit")
    if "." not in normalized:
        if abs(int(normalized)) > MAX_SAFE_JSON_INTEGER:
            raise PerformanceContractError(f"{field} exceeds the exact JSON integer range")
    elif not isinstance(value, str):
        rendered = float(normalized)
        if not math.isfinite(rendered) or Decimal(str(rendered)) != Decimal(normalized):
            raise PerformanceContractError(f"{field} cannot be represented as an exact JSON number")
    return normalized


def decimal_json(value: str) -> int | Decimal:
    """Render one canonical decimal string as an exact JSON-number value."""
    if "." not in value:
        return int(value)
    return Decimal(value)


def decimal_wire(value: str) -> int | str:
    """Render exact normalized wire values without binary decimal rounding."""
    if "." not in value:
        return int(value)
    return value


def normalize_dimensions(value: Any, field: str) -> dict[str, str | int | float | bool]:
    """Normalize bounded Phase 1-compatible scalar dimensions."""
    if not isinstance(value, dict):
        raise PerformanceContractError(f"{field} must be an object")
    if len(value) > 32:
        raise PerformanceContractError(f"{field} exceeds 32 entries")
    output: dict[str, str | int | float | bool] = {}
    for key, item in sorted(value.items()):
        if not isinstance(key, str) or not DIMENSION_KEY_RE.fullmatch(key):
            raise PerformanceContractError(f"{field} keys must use bounded lower_snake_case")
        if key in RESERVED_DIMENSION_KEYS:
            raise PerformanceContractError(
                f"{field}.{key} must use its dedicated scope or measurement field"
            )
        if DIRECT_DIMENSION_KEY_RE.search(key):
            raise PerformanceContractError(f"{field}.{key} cannot contain direct identifiers")
        item_field = f"{field}.{key}"
        if isinstance(item, bool):
            output[key] = item
        elif isinstance(item, (int, float, Decimal)):
            normalized = decimal_text(item, item_field)
            if contains_direct_identifier(normalized):
                raise PerformanceContractError(
                    f"{item_field} cannot contain direct identifiers"
                )
            output[key] = int(normalized) if "." not in normalized else float(normalized)
        elif isinstance(item, str) and 0 < len(item) <= 128 and not CONTROL_RE.search(item):
            if contains_direct_identifier(item):
                raise PerformanceContractError(
                    f"{item_field} cannot contain direct identifiers"
                )
            output[key] = item
        else:
            raise PerformanceContractError(
                f"{item_field} must be a bounded scalar string, number, or boolean"
            )
    return output


def canonical_json(value: Any) -> str:
    """Serialize deterministic JSON used for immutable fingerprints."""
    return wire_json(value)


def wire_json(value: Any) -> str:
    """Serialize JSON while preserving Decimal values as exact number tokens."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, Decimal):
        if not value.is_finite():
            raise PerformanceContractError("JSON decimal must be finite")
        return format(value, "f")
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return json.dumps(value, allow_nan=False)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=True)
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(wire_json(item) for item in value) + "]"
    if isinstance(value, dict):
        if not all(isinstance(key, str) for key in value):
            raise PerformanceContractError("JSON object keys must be strings")
        return "{" + ",".join(
            f"{json.dumps(key, ensure_ascii=True)}:{wire_json(value[key])}"
            for key in sorted(value)
        ) + "}"
    raise PerformanceContractError("value is not JSON serializable")


def validate_batch_header(batch: Any) -> dict[str, Any]:
    """Validate source/account isolation, freshness, and cursor metadata."""
    if not isinstance(batch, dict):
        raise PerformanceContractError("batch must be an object")
    source = batch.get("source")
    if not isinstance(source, str) or source not in SOURCE_KINDS:
        raise PerformanceContractError("batch.source is unsupported")
    account_ref = require_alias(batch.get("account_ref"), "batch.account_ref")
    observed_at = parse_timestamp(batch.get("observed_at"), "batch.observed_at")
    coverage = batch.get("coverage", "unknown")
    if not isinstance(coverage, str) or coverage not in COMPLETENESS:
        raise PerformanceContractError("batch.coverage is unsupported")
    cursor = batch.get("cursor")
    if cursor is not None:
        cursor = require_private_ref(cursor, "batch.cursor")
    missing_scopes_raw = batch.get("missing_scopes", [])
    if not isinstance(missing_scopes_raw, list):
        raise PerformanceContractError("batch.missing_scopes must be an array")
    missing_scopes = sorted(
        {require_alias(item, "batch.missing_scopes[]") for item in missing_scopes_raw}
    )
    events = batch.get("events")
    if not isinstance(events, list):
        raise PerformanceContractError("batch.events must be an array")
    return {
        "source": source,
        "account_ref": account_ref,
        "cursor": cursor,
        "observed_at": observed_at,
        "coverage": coverage,
        "missing_scopes": missing_scopes,
        "events": events,
    }


def _normalize_subject(subject: Any) -> dict[str, Any]:
    if not isinstance(subject, dict):
        raise PerformanceContractError("event.subject must be an object")
    kind = subject.get("kind")
    identity_state = subject.get("identity_state")
    if not isinstance(kind, str) or kind not in SUBJECT_KINDS:
        raise PerformanceContractError("event.subject.kind is unsupported")
    if not isinstance(identity_state, str) or identity_state not in IDENTITY_STATES:
        raise PerformanceContractError("event.subject.identity_state is unsupported")
    source_ref = subject.get("source_ref")
    candidates_raw = subject.get("candidate_refs", [])
    if not isinstance(candidates_raw, list):
        raise PerformanceContractError("event.subject.candidate_refs must be an array")
    candidates = [
        require_private_ref(candidate, "event.subject.candidate_refs[]")
        for candidate in candidates_raw
    ]
    if kind == "aggregate":
        if source_ref is not None or candidates or identity_state != "not_applicable":
            raise PerformanceContractError("aggregate subjects cannot carry identity references")
    elif identity_state == "ambiguous":
        if source_ref is not None or len(set(candidates)) < 2:
            raise PerformanceContractError("ambiguous subjects require at least two candidates")
    else:
        if identity_state in {"linked", "split"}:
            raise PerformanceContractError(
                "linked and split identity states require owner reconciliation"
            )
        if identity_state != "isolated":
            raise PerformanceContractError("resolved source subjects must be isolated")
        source_ref = require_private_ref(source_ref, "event.subject.source_ref")
        if candidates:
            raise PerformanceContractError("resolved subjects cannot carry candidate refs")
    return {
        "kind": kind,
        "identity_state": identity_state,
        "source_ref": source_ref,
        "candidate_refs": sorted(set(candidates)),
    }


def _normalize_scope(scope: Any) -> dict[str, Any]:
    if scope is None:
        scope = {}
    if not isinstance(scope, dict):
        raise PerformanceContractError("event.scope must be an object")
    allowed = {
        "campaign_id",
        "channel",
        "creative_id",
        "touchpoint_id",
        "outcome_id",
        "dimensions",
    }
    extras = set(scope) - allowed
    if extras:
        raise PerformanceContractError(f"event.scope has unsupported fields: {', '.join(sorted(extras))}")
    dimensions = normalize_dimensions(
        scope.get("dimensions", {}),
        "event.scope.dimensions",
    )
    normalized = {
        field: optional_alias(scope.get(field), f"event.scope.{field}")
        for field in ("campaign_id", "channel", "creative_id", "touchpoint_id", "outcome_id")
    }
    normalized["dimensions"] = dimensions
    return normalized


def _normalize_measurement(measurement: Any, event_type: str) -> dict[str, Any]:
    if not isinstance(measurement, dict):
        raise PerformanceContractError("event.measurement must be an object")
    metric_id = measurement.get("metric_id")
    if not isinstance(metric_id, str) or not METRIC_RE.fullmatch(metric_id):
        raise PerformanceContractError("event.measurement.metric_id is invalid")
    unit = measurement.get("unit")
    aggregation = measurement.get("aggregation", "sum")
    if not isinstance(unit, str) or unit not in UNITS:
        raise PerformanceContractError("event.measurement.unit is unsupported")
    if not isinstance(aggregation, str) or aggregation not in AGGREGATIONS:
        raise PerformanceContractError("event.measurement.aggregation is unsupported")
    currency = measurement.get("currency")
    if unit == "currency":
        if not isinstance(currency, str) or not re.fullmatch(r"[A-Z]{3}", currency):
            raise PerformanceContractError("currency measurements require an ISO currency")
    elif currency is not None:
        raise PerformanceContractError("non-currency measurements cannot carry currency")
    contract = METRIC_CONTRACTS.get(metric_id)
    if contract is None:
        raise PerformanceContractError("event.measurement.metric_id is unsupported")
    event_types, expected_unit, aggregations = contract
    if event_type != "correction" and event_type not in event_types:
        raise PerformanceContractError("event type does not match metric identity")
    if unit != expected_unit:
        raise PerformanceContractError("measurement unit does not match metric identity")
    if aggregation not in aggregations:
        raise PerformanceContractError("measurement aggregation does not match metric identity")
    period_start_raw = measurement.get("period_start")
    period_end_raw = measurement.get("period_end")
    if (period_start_raw is None) != (period_end_raw is None):
        raise PerformanceContractError("measurement periods require both start and end")
    period_start = None
    period_end = None
    if period_start_raw is not None:
        period_start = parse_timestamp(period_start_raw, "event.measurement.period_start")
        period_end = parse_timestamp(period_end_raw, "event.measurement.period_end")
        if timestamp_epoch(period_start) > timestamp_epoch(period_end):
            raise PerformanceContractError("measurement period start must not follow end")
    return {
        "metric_id": metric_id,
        "value": decimal_text(measurement.get("value"), "event.measurement.value"),
        "unit": unit,
        "aggregation": aggregation,
        "currency": currency,
        "period_start": period_start,
        "period_end": period_end,
    }


def _normalize_quality(quality: Any, batch_coverage: str) -> dict[str, Any]:
    if not isinstance(quality, dict):
        raise PerformanceContractError("event.quality must be an object")
    confidence = quality.get("confidence", "medium")
    completeness = quality.get("completeness", batch_coverage)
    source_type = quality.get("source_type", "api_export")
    collected_by = require_alias(quality.get("collected_by"), "event.quality.collected_by")
    if not isinstance(confidence, str) or confidence not in CONFIDENCE:
        raise PerformanceContractError("event.quality.confidence is unsupported")
    if not isinstance(completeness, str) or completeness not in COMPLETENESS:
        raise PerformanceContractError("event.quality.completeness is unsupported")
    if not isinstance(source_type, str) or source_type not in SOURCE_TYPES:
        raise PerformanceContractError("event.quality.source_type is unsupported")
    verified_by = quality.get("verified_by")
    if confidence == "verified":
        if completeness != "complete" or batch_coverage != "complete":
            raise PerformanceContractError("partial or unknown evidence cannot be verified")
        verified_by = require_alias(verified_by, "event.quality.verified_by")
    elif verified_by is not None:
        verified_by = require_alias(verified_by, "event.quality.verified_by")
    return {
        "confidence": confidence,
        "completeness": completeness,
        "source_type": source_type,
        "collected_by": collected_by,
        "verified_by": verified_by,
    }


def _normalize_governance(governance: Any, subject_kind: str) -> dict[str, Any]:
    if governance is None:
        governance = {}
    if not isinstance(governance, dict):
        raise PerformanceContractError("event.governance must be an object")
    consent_raw = governance.get("consent", [])
    if not isinstance(consent_raw, list):
        raise PerformanceContractError("event.governance.consent must be an array")
    consent: list[dict[str, Any]] = []
    for index, entry in enumerate(consent_raw):
        if not isinstance(entry, dict):
            raise PerformanceContractError(f"event.governance.consent[{index}] must be an object")
        purpose = entry.get("purpose")
        state = entry.get("state")
        if not isinstance(purpose, str) or purpose not in {"measurement", "audience"}:
            raise PerformanceContractError("consent purpose is unsupported")
        if not isinstance(state, str) or state not in {"granted", "denied", "unknown"}:
            raise PerformanceContractError("consent state is unsupported")
        lawful_basis = optional_alias(
            entry.get("lawful_basis"),
            "consent lawful_basis",
        )
        consent.append(
            {
                "purpose": purpose,
                "state": state,
                "lawful_basis": lawful_basis,
                "effective_at": parse_timestamp(entry.get("effective_at"), "consent.effective_at"),
            }
        )
    suppression_raw = governance.get("suppression")
    suppression: dict[str, Any] | None = None
    if suppression_raw is not None:
        if not isinstance(suppression_raw, dict):
            raise PerformanceContractError("event.governance.suppression must be an object")
        state = suppression_raw.get("state")
        if not isinstance(state, str) or state not in {"clear", "suppressed"}:
            raise PerformanceContractError("suppression state is unsupported")
        reason = optional_alias(
            suppression_raw.get("reason"),
            "suppression reason",
        )
        suppression = {
            "state": state,
            "reason": reason,
            "effective_at": parse_timestamp(
                suppression_raw.get("effective_at"), "suppression.effective_at"
            ),
        }
    if subject_kind == "aggregate" and (consent or suppression is not None):
        raise PerformanceContractError("aggregate events cannot carry subject governance")
    return {"consent": consent, "suppression": suppression}


def validate_event(
    event: Any,
    batch_coverage: str,
    missing_scopes: list[str] | None = None,
) -> dict[str, Any]:
    """Normalize one adapter event while retaining private refs only in memory."""
    if not isinstance(event, dict):
        raise PerformanceContractError("event must be an object")
    source_event_id = require_private_ref(event.get("source_event_id"), "event.source_event_id")
    revision = event.get("revision", 1)
    if (
        not isinstance(revision, int)
        or isinstance(revision, bool)
        or not 1 <= revision <= MAX_SAFE_JSON_INTEGER
    ):
        raise PerformanceContractError("event.revision must be a bounded positive integer")
    event_type = event.get("event_type")
    if not isinstance(event_type, str) or event_type not in EVENT_TYPES:
        raise PerformanceContractError("event.event_type is unsupported")
    occurred_at = parse_timestamp(event.get("occurred_at"), "event.occurred_at")
    source_observed_at = event.get("source_observed_at")
    if source_observed_at is not None:
        source_observed_at = parse_timestamp(
            source_observed_at,
            "event.source_observed_at",
        )
    source_recorded_at = event.get("source_recorded_at")
    if source_recorded_at is not None:
        source_recorded_at = parse_timestamp(
            source_recorded_at,
            "event.source_recorded_at",
        )
    correction_of = event.get("correction_of")
    if correction_of is not None:
        correction_of = require_private_ref(correction_of, "event.correction_of")
    if event_type == "correction" and correction_of is None:
        raise PerformanceContractError("correction events require correction_of")
    if event_type != "correction" and correction_of is not None:
        raise PerformanceContractError("only correction events may carry correction_of")
    if correction_of == source_event_id:
        raise PerformanceContractError("correction events cannot correct themselves")
    subject = _normalize_subject(event.get("subject"))
    measurement = _normalize_measurement(event.get("measurement"), event_type)
    if (
        Decimal(measurement["value"]) < 0
        and event_type != "correction"
        and measurement["unit"] != "ratio"
    ):
        raise PerformanceContractError("non-correction count and currency values cannot be negative")
    effective_coverage = "partial" if missing_scopes else batch_coverage
    governance = _normalize_governance(event.get("governance"), subject["kind"])
    if event_type == "unsubscribe":
        suppression = governance["suppression"]
        audience_entries = [
            entry for entry in governance["consent"] if entry["purpose"] == "audience"
        ]
        audience_denied = bool(audience_entries) and all(
            entry["state"] == "denied"
            and timestamp_epoch(entry["effective_at"]) <= timestamp_epoch(occurred_at)
            for entry in audience_entries
        )
        suppression_active = bool(
            suppression is not None
            and suppression["state"] == "suppressed"
            and timestamp_epoch(suppression["effective_at"]) <= timestamp_epoch(occurred_at)
        )
        if not suppression_active or not audience_denied:
            raise PerformanceContractError(
                "unsubscribe events require audience denial and active suppression"
            )
    normalized = {
        "source_event_id": source_event_id,
        "revision": revision,
        "event_type": event_type,
        "occurred_at": occurred_at,
        "source_observed_at": source_observed_at,
        "source_recorded_at": source_recorded_at,
        "correction_of": correction_of,
        "subject": subject,
        "scope": _normalize_scope(event.get("scope")),
        "measurement": measurement,
        "quality": _normalize_quality(event.get("quality"), effective_coverage),
        "governance": governance,
    }
    return normalized


def event_for_fingerprint(event: dict[str, Any]) -> dict[str, Any]:
    """Return a detached deterministic event payload for conflict checks."""
    payload = deepcopy(event)
    if not payload["scope"].get("dimensions"):
        payload["scope"].pop("dimensions", None)
    return payload


def metric_definition(metric_id: str, unit: str) -> dict[str, Any]:
    """Build stable Phase 1 metric metadata for one normalized measurement."""
    label, kind, description = METRIC_DEFINITIONS.get(
        metric_id,
        (metric_id.rsplit(".", 1)[-1].replace("_", " ").title(), "currency" if unit == "currency" else "ratio" if unit == "ratio" else "count", "Provider-neutral normalized marketing outcome"),
    )
    return {
        "id": metric_id,
        "label": label,
        "description": description,
        "domain": "marketing",
        "kind": kind,
        "owner": "performance-plane",
        "version": 1,
    }


def metric_event_type(metric_id: str) -> str:
    """Return the canonical non-correction event type for one v1 metric."""
    contract = METRIC_CONTRACTS.get(metric_id)
    if contract is None:
        raise PerformanceContractError("legacy metric identity is unsupported")
    return sorted(contract[0])[0]
