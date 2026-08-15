#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared strict-validation primitives for optimization artifacts."""

from __future__ import annotations

import re
from typing import Any

from marketing_optimization_contract import (
    OptimizationError,
    number,
    parse_datetime,
    require_integer,
    require_list,
    require_object,
    typed_reference,
)
from performance_contract import require_alias

SHA256_REF_RE = re.compile(r"^sha256:[a-f0-9]{64}$")
ATTRIBUTION_REF_RE = re.compile(r"^mkt-attribution-v1:[a-f0-9]{64}$")
EXPERIMENT_REF_RE = re.compile(r"^mkt-experiment-v1:[a-f0-9]{64}$")
EXPERIMENT_RUN_REF_RE = re.compile(r"^mkt-experiment-run-v1:[a-f0-9]{64}$")
REPORT_REF_RE = re.compile(r"^mkt-report-v1:[a-f0-9]{64}$")
RECOMMENDATION_REF_RE = re.compile(r"^mkt-recommendation-v1:[a-f0-9]{64}$")
EVIDENCE_REF_RE = re.compile(r"^mkt-evidence-v1:sha256:[a-f0-9]{64}$")
RECORD_REF_RE = re.compile(r"^mkt-record-v1:[a-f0-9]{64}$")
ASSIGNMENT_REF_RE = re.compile(r"^mkt-assignment-v1:sha256:[a-f0-9]{64}$")
CURRENCY_RE = re.compile(r"^[A-Z]{3}$")
EVIDENCE_LINK_RE = re.compile(
    r"^(?:mkt-attribution-v1|mkt-experiment-run-v1|mkt-report-v1|mkt-evidence-v1:sha256):[a-f0-9]{64}$"
)
FORBIDDEN_SIDE_EFFECTS = {
    "publish",
    "message",
    "spend",
    "retarget",
    "change_offer",
    "mutate_account",
    "export_audience",
}
ATTRIBUTION_CAUSAL_STATEMENT = "Attribution describes observed associations and does not establish causal lift."
REPORT_CAUSAL_STATEMENT = (
    "Observational performance and attribution do not establish growth causality; "
    "only eligible verified experiments can support causal wording."
)
RECOMMENDATION_CAUSAL_WORDING = {
    "causal_supported": (
        "The verified preregistered experiment supports a causal effect within its measured population and window."
    ),
    "observational_only": (
        "Observed attribution suggests an aggregate association that requires a controlled experiment before causal use."
    ),
    "insufficient_evidence": "Evidence is insufficient; only an instrumentation improvement is recommended.",
    "contradicted": "Evidence is contradictory and does not support a causal conclusion.",
}


def exact(value: Any, fields: set[str], label: str) -> dict[str, Any]:
    """Require one object with exactly the declared fields."""
    document = require_object(value, label)
    if set(document) != fields:
        raise OptimizationError(f"{label} fields are invalid")
    return document


def enum_value(value: Any, allowed: set[str], label: str) -> str:
    """Require one enumerated string."""
    if not isinstance(value, str) or value not in allowed:
        raise OptimizationError(f"{label} is unsupported")
    return value


def boolean(value: Any, label: str) -> bool:
    """Require one JSON boolean."""
    if not isinstance(value, bool):
        raise OptimizationError(f"{label} must be boolean")
    return value


def optional_count(value: Any, label: str) -> None:
    """Validate one nullable non-negative safe integer."""
    if value is not None:
        require_integer(value, label, 0, 9_007_199_254_740_991)


def optional_number(value: Any, label: str) -> None:
    """Validate one nullable exact decimal."""
    if value is not None:
        number(value, label)


def optional_timestamp(value: Any, label: str) -> None:
    """Validate one nullable UTC timestamp."""
    if value is not None:
        parse_datetime(value, label)


def currency(value: Any, label: str) -> None:
    """Validate one nullable ISO-style currency alias."""
    if value is not None and (not isinstance(value, str) or not CURRENCY_RE.fullmatch(value)):
        raise OptimizationError(f"{label} must be a three-letter uppercase currency")


def reference(value: Any, pattern: re.Pattern[str], label: str) -> str:
    """Require one typed digest reference."""
    selected = str(value or "")
    if not pattern.fullmatch(selected):
        raise OptimizationError(f"{label} is invalid")
    return selected


def reference_list(value: Any, pattern: re.Pattern[str], label: str) -> list[str]:
    """Require a unique list of typed digest references."""
    references = [reference(item, pattern, label) for item in require_list(value, label)]
    if len(references) != len(set(references)):
        raise OptimizationError(f"{label} must contain unique references")
    return references


def alias_list(value: Any, label: str) -> list[str]:
    """Require a unique list of privacy-safe aliases."""
    aliases = [require_alias(item, label) for item in require_list(value, label)]
    if len(aliases) != len(set(aliases)):
        raise OptimizationError(f"{label} must contain unique aliases")
    return aliases


def content_reference(
    document: dict[str, Any],
    field: str,
    prefix: str,
    pattern: re.Pattern[str],
    label: str,
) -> str:
    """Verify one declared content-derived reference."""
    selected = reference(document.get(field), pattern, f"{label} reference")
    body = {key: value for key, value in document.items() if key != field}
    if typed_reference(prefix, body) != selected:
        raise OptimizationError(f"{label} reference does not match its content")
    return selected
