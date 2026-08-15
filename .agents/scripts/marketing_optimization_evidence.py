#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reusable evidence-scope validation for marketing optimization artifacts."""

from __future__ import annotations

from typing import Any

from marketing_optimization_contract import OptimizationError, require_object


def validate_scope_binding(
    scope: dict[str, Any],
    account_ref: str | None,
    campaign_id: str | None,
    label: str,
) -> None:
    """Reject evidence that names a different observable account or campaign."""
    expected = {"account_ref": account_ref, "campaign_id": campaign_id}
    mismatched = [field for field, value in expected.items() if scope.get(field) != value]
    if mismatched:
        raise OptimizationError(f"{label} scope does not match the report snapshot")


def validate_report_evidence_scopes(
    report_scope: dict[str, Any],
    evidence: list[dict[str, Any]],
) -> None:
    """Require report evidence to agree with every declared report scope."""
    for item in evidence:
        item_scope = require_object(item.get("scope"), "report evidence scope")
        mismatched = [
            field
            for field in ("account_ref", "campaign_id")
            if item_scope.get(field) != report_scope.get(field)
        ]
        if mismatched:
            raise OptimizationError("report evidence scope is inconsistent")
