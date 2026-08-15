#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Quality and governance normalization for performance events."""

from __future__ import annotations

from typing import Any

from _performance_contract_definitions import (
    COMPLETENESS, CONFIDENCE, SOURCE_TYPES, PerformanceContractError,
)
from _performance_contract_values import (
    optional_alias, parse_timestamp, require_alias, timestamp_epoch,
)


def _validate_quality_values(confidence: Any, completeness: Any, source_type: Any) -> None:
    if not isinstance(confidence, str) or confidence not in CONFIDENCE:
        raise PerformanceContractError("event.quality.confidence is unsupported")
    if not isinstance(completeness, str) or completeness not in COMPLETENESS:
        raise PerformanceContractError("event.quality.completeness is unsupported")
    if not isinstance(source_type, str) or source_type not in SOURCE_TYPES:
        raise PerformanceContractError("event.quality.source_type is unsupported")


def _verified_by(quality: dict[str, Any], confidence: str, completeness: str, batch_coverage: str) -> Any:
    verified_by = quality.get("verified_by")
    verified_incomplete = confidence == "verified" and (
        completeness != "complete" or batch_coverage != "complete"
    )
    if verified_incomplete:
        raise PerformanceContractError("partial or unknown evidence cannot be verified")
    if confidence == "verified" or verified_by is not None:
        verified_by = require_alias(verified_by, "event.quality.verified_by")
    return verified_by


def normalize_quality(quality: Any, batch_coverage: str) -> dict[str, Any]:
    """Normalize bounded source quality metadata."""
    if not isinstance(quality, dict):
        raise PerformanceContractError("event.quality must be an object")
    confidence = quality.get("confidence", "medium")
    completeness = quality.get("completeness", batch_coverage)
    source_type = quality.get("source_type", "api_export")
    collected_by = require_alias(quality.get("collected_by"), "event.quality.collected_by")
    _validate_quality_values(confidence, completeness, source_type)
    verified_by = _verified_by(quality, confidence, completeness, batch_coverage)
    return {"confidence": confidence, "completeness": completeness, "source_type": source_type, "collected_by": collected_by, "verified_by": verified_by}


def _consent_entry(entry: Any, index: int) -> dict[str, Any]:
    if not isinstance(entry, dict):
        raise PerformanceContractError(f"event.governance.consent[{index}] must be an object")
    purpose, state = entry.get("purpose"), entry.get("state")
    if not isinstance(purpose, str) or purpose not in {"measurement", "audience"}:
        raise PerformanceContractError("consent purpose is unsupported")
    if not isinstance(state, str) or state not in {"granted", "denied", "unknown"}:
        raise PerformanceContractError("consent state is unsupported")
    return {
        "purpose": purpose,
        "state": state,
        "lawful_basis": optional_alias(entry.get("lawful_basis"), "consent lawful_basis"),
        "effective_at": parse_timestamp(entry.get("effective_at"), "consent.effective_at"),
    }


def _suppression(value: Any) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise PerformanceContractError("event.governance.suppression must be an object")
    state = value.get("state")
    if not isinstance(state, str) or state not in {"clear", "suppressed"}:
        raise PerformanceContractError("suppression state is unsupported")
    return {
        "state": state,
        "reason": optional_alias(value.get("reason"), "suppression reason"),
        "effective_at": parse_timestamp(value.get("effective_at"), "suppression.effective_at"),
    }


def normalize_governance(governance: Any, subject_kind: str) -> dict[str, Any]:
    """Normalize append-only consent and suppression evidence."""
    governance = {} if governance is None else governance
    if not isinstance(governance, dict):
        raise PerformanceContractError("event.governance must be an object")
    consent_raw = governance.get("consent", [])
    if not isinstance(consent_raw, list):
        raise PerformanceContractError("event.governance.consent must be an array")
    consent = [_consent_entry(entry, index) for index, entry in enumerate(consent_raw)]
    suppression = _suppression(governance.get("suppression"))
    if subject_kind == "aggregate" and (consent or suppression is not None):
        raise PerformanceContractError("aggregate events cannot carry subject governance")
    return {"consent": consent, "suppression": suppression}


def _audience_denied(governance: dict[str, Any], occurred_at: str) -> bool:
    audience = [entry for entry in governance["consent"] if entry["purpose"] == "audience"]
    return bool(audience) and all(
        entry["state"] == "denied" and timestamp_epoch(entry["effective_at"]) <= timestamp_epoch(occurred_at)
        for entry in audience
    )


def _suppression_timely(governance: dict[str, Any], occurred_at: str) -> bool:
    suppression = governance["suppression"]
    suppression_active = suppression is not None and suppression["state"] == "suppressed"
    return suppression_active and timestamp_epoch(suppression["effective_at"]) <= timestamp_epoch(occurred_at)


def validate_unsubscribe(governance: dict[str, Any], occurred_at: str) -> None:
    """Require timely audience denial and suppression for unsubscribe events."""
    audience_denied = _audience_denied(governance, occurred_at)
    suppression_timely = _suppression_timely(governance, occurred_at)
    if not suppression_timely or not audience_denied:
        raise PerformanceContractError("unsubscribe events require audience denial and active suppression")
