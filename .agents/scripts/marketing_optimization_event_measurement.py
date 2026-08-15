#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Measurement validation for normalized marketing performance events."""

from __future__ import annotations

import re
from decimal import Decimal
from typing import Any

from marketing_optimization_event_validation_common import nullable_timestamp, object_fields
from performance_contract import (
    AGGREGATIONS,
    METRIC_CONTRACTS,
    UNITS,
    PerformanceContractError,
    decimal_text,
    timestamp_epoch,
)

CURRENCY_RE = re.compile(r"^[A-Z]{3}$")


def _validate_metric_contract(measurement: dict[str, Any], event_type: str) -> None:
    """Bind catalogued metric identities to event, unit, and aggregation rules."""
    contract = METRIC_CONTRACTS.get(measurement["metric_id"])
    if contract is None:
        return
    event_types, expected_unit, aggregations = contract
    if event_type != "correction" and event_type not in event_types:
        raise PerformanceContractError("event type does not match metric identity")
    if measurement["unit"] != expected_unit or measurement["aggregation"] not in aggregations:
        raise PerformanceContractError("measurement does not match metric identity")


def _validate_currency(unit: str, currency: Any) -> None:
    """Require currency exactly for currency-valued measurements."""
    if unit == "currency":
        if not isinstance(currency, str) or not CURRENCY_RE.fullmatch(currency):
            raise PerformanceContractError("event.measurement currency is inconsistent")
        return
    if currency is not None:
        raise PerformanceContractError("event.measurement currency is inconsistent")


def _validate_period(measurement: dict[str, Any]) -> None:
    """Require complete chronologically ordered optional periods."""
    period_start = nullable_timestamp(measurement.get("period_start"), "event.measurement.period_start")
    period_end = nullable_timestamp(measurement.get("period_end"), "event.measurement.period_end")
    if (period_start is None) != (period_end is None):
        raise PerformanceContractError("measurement periods require both start and end")
    if period_start is not None and timestamp_epoch(period_start) > timestamp_epoch(str(period_end)):
        raise PerformanceContractError("measurement period start must not follow end")


def validate_measurement(value: Any, event_type: str) -> None:
    """Validate exact metric values, units, periods, and optional catalog rules."""
    required = {"metric_id", "value", "unit", "aggregation", "currency"}
    measurement = object_fields(value, "event.measurement", required, {"period_start", "period_end"})
    metric_id = measurement["metric_id"]
    if not isinstance(metric_id, str) or not re.fullmatch(r"marketing\.[a-z0-9_]+(?:\.[a-z0-9_]+)+", metric_id):
        raise PerformanceContractError("event.measurement.metric_id is invalid")
    unit = measurement["unit"]
    aggregation = measurement["aggregation"]
    if unit not in UNITS or aggregation not in AGGREGATIONS:
        raise PerformanceContractError("event.measurement unit or aggregation is unsupported")
    _validate_metric_contract(measurement, event_type)
    normalized_value = decimal_text(measurement["value"], "event.measurement.value")
    if Decimal(normalized_value) < 0 and event_type != "correction" and unit != "ratio":
        raise PerformanceContractError("non-correction count and currency values cannot be negative")
    _validate_currency(str(unit), measurement["currency"])
    _validate_period(measurement)
