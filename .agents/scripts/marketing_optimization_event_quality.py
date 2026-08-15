#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Quality and provenance validation for normalized optimization events."""

from __future__ import annotations

from typing import Any

from performance_contract import (
    COMPLETENESS,
    CONFIDENCE,
    SOURCE_TYPES,
    PerformanceContractError,
    require_alias,
)

CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2, "verified": 3}


def validate_event_quality(value: Any, source: dict[str, Any], evidence_ref: str) -> None:
    """Validate bounded quality labels and matching evidence provenance."""
    fields = {"confidence", "effective_confidence", "completeness", "source_type", "collected_by", "evidence_ref"}
    if not isinstance(value, dict) or set(value) != fields:
        raise PerformanceContractError("event.quality fields do not match the normalized event contract")
    confidence = value["confidence"]
    effective = value["effective_confidence"]
    if confidence not in CONFIDENCE or effective not in CONFIDENCE or value["completeness"] not in COMPLETENESS:
        raise PerformanceContractError("event.quality confidence or completeness is unsupported")
    if value["source_type"] not in SOURCE_TYPES:
        raise PerformanceContractError("event.quality.source_type is unsupported")
    require_alias(value["collected_by"], "event.quality.collected_by")
    if value["evidence_ref"] != evidence_ref or CONFIDENCE_RANK[str(effective)] > CONFIDENCE_RANK[str(confidence)]:
        raise PerformanceContractError("event.quality provenance or effective confidence is inconsistent")
    if (source["coverage"] != "complete" or value["completeness"] != "complete") and effective == "verified":
        raise PerformanceContractError("partial or unknown evidence cannot be verified")
