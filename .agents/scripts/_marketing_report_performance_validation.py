#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Performance and attribution sections embedded in optimization reports."""

from __future__ import annotations

from typing import Any

from marketing_attribution_validation import (
    AttributionPrivacyContext,
    validate_allocation,
    validate_attribution_privacy,
    validate_attribution_scope,
    validate_costs,
    validate_coverage,
    validate_model,
    validate_outcomes,
    validate_window,
)
from marketing_optimization_contract import (
    MINIMUM_AGGREGATE_CELL_SIZE,
    OptimizationError,
    parse_datetime,
    require_list,
    require_object,
    require_metric,
)
from marketing_optimization_validation_common import (
    ATTRIBUTION_REF_RE,
    SHA256_REF_RE,
    alias_list,
    boolean,
    currency,
    enum_value,
    exact,
    optional_count,
    optional_number,
    reference,
)
from performance_contract import optional_alias, require_alias


def validate_report_row(value: Any, label: str) -> None:
    """Validate one privacy-gated aggregate report row."""
    fields = {
        "category", "metric_id", "campaign_id", "channel", "creative_id", "touchpoint_id",
        "dimensions", "unit", "currency", "value", "record_count", "suppressed", "suppression_reason",
    }
    row = exact(value, fields, label)
    require_alias(row["category"], f"{label}.category")
    require_metric(row["metric_id"], f"{label}.metric_id")
    for field in ("campaign_id", "channel", "creative_id", "touchpoint_id"):
        optional_alias(row[field], f"{label}.{field}")
    if row["dimensions"] is not None:
        dimensions = require_object(row["dimensions"], f"{label}.dimensions")
        if not set(dimensions).issubset({"cohort", "environment", "region"}):
            raise OptimizationError(f"{label}.dimensions contains an unsupported key")
        for field, item in dimensions.items():
            require_alias(item, f"{label}.dimensions.{field}")
    require_alias(row["unit"], f"{label}.unit")
    currency(row["currency"], f"{label}.currency")
    optional_number(row["value"], f"{label}.value")
    optional_count(row["record_count"], f"{label}.record_count")
    boolean(row["suppressed"], f"{label}.suppressed")
    if row["suppression_reason"] not in {None, "below_minimum_cell_size"}:
        raise OptimizationError(f"{label}.suppression_reason is unsupported")
    hidden_fields = ("campaign_id", "channel", "creative_id", "touchpoint_id", "dimensions", "value", "record_count")
    if row["suppressed"]:
        hidden_values = any(row[field] is not None for field in hidden_fields)
        if row["suppression_reason"] != "below_minimum_cell_size" or hidden_values:
            raise OptimizationError(f"{label} exposes a suppressed report cell")
        return
    if row["suppression_reason"] is not None or row["value"] is None:
        raise OptimizationError(f"{label} has inconsistent suppression metadata")
    record_count = row["record_count"]
    invalid_count = not isinstance(record_count, int) or isinstance(record_count, bool)
    if invalid_count or record_count < MINIMUM_AGGREGATE_CELL_SIZE:
        raise OptimizationError(f"{label}.record_count is below the privacy floor")


def validate_attribution_summary(value: Any, label: str) -> None:
    """Validate one attribution section embedded in a report."""
    fields = {
        "attribution_ref", "input_snapshot_sha256", "as_of", "model", "scope", "window", "run_status",
        "outcomes", "costs", "allocations", "coverage", "data_confidence", "uncertainty_reasons", "causal_status",
    }
    summary = exact(value, fields, label)
    reference(summary["attribution_ref"], ATTRIBUTION_REF_RE, f"{label}.attribution_ref")
    reference(summary["input_snapshot_sha256"], SHA256_REF_RE, f"{label}.input_snapshot_sha256")
    parse_datetime(summary["as_of"], f"{label}.as_of")
    validate_model(summary["model"], f"{label}.model")
    validate_attribution_scope(summary["scope"], f"{label}.scope")
    validate_window(summary["window"], f"{label}.window")
    enum_value(summary["run_status"], {"complete", "partial", "insufficient_evidence"}, f"{label}.run_status")
    validate_outcomes(summary["outcomes"], f"{label}.outcomes")
    validate_costs(summary["costs"], f"{label}.costs")
    allocations = require_list(summary["allocations"], f"{label}.allocations")
    for index, item in enumerate(allocations):
        validate_allocation(item, f"{label}.allocations[{index}]")
    validate_coverage(summary["coverage"], f"{label}.coverage")
    privacy = AttributionPrivacyContext(
        summary["outcomes"], summary["costs"], allocations, summary["coverage"], summary["run_status"], label
    )
    validate_attribution_privacy(privacy)
    enum_value(summary["data_confidence"], {"low", "medium", "high", "verified"}, f"{label}.data_confidence")
    alias_list(summary["uncertainty_reasons"], f"{label}.uncertainty_reasons")
    if summary["causal_status"] != "observational_only":
        raise OptimizationError(f"{label} must remain observational")
