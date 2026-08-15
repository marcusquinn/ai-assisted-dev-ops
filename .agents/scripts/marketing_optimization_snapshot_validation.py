#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation for optimization subject projections and source summaries."""

from __future__ import annotations

from typing import Any

from marketing_optimization_contract import (
    SUBJECT_REF_RE,
    OptimizationError,
    assert_public_safe,
    identity_is_uncertain,
)
from performance_contract import COMPLETENESS, SOURCE_KINDS, optional_alias, parse_timestamp, require_alias

SUBJECT_KINDS = {"anonymous", "lead", "contact", "account", "audience"}
IDENTITY_STATES = {"isolated", "linked", "split", "ambiguous"}
ELIGIBILITY_REASONS = {
    "eligible",
    "consent_unknown",
    "consent_denied",
    "suppressed",
    "identity_ambiguous",
    "subject_ineligible",
}
SOURCE_STATUSES = {"ready", "partial", "leased", "stale", "unavailable", "unknown"}


def _object(value: Any, label: str, required: set[str], optional: set[str] | None = None) -> dict[str, Any]:
    """Require one exact bounded snapshot object."""
    if not isinstance(value, dict):
        raise OptimizationError(f"{label} must be an object")
    if required - set(value) or set(value) - required - (optional or set()):
        raise OptimizationError(f"{label} fields do not match the snapshot contract")
    return value


def _nonnegative_integer(value: Any, label: str, *, nullable: bool = False) -> None:
    """Require a non-negative integer or an explicitly allowed null."""
    if nullable and value is None:
        return
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise OptimizationError(f"{label} must be a non-negative integer")


def validate_subject_projection(value: Any, index: int) -> dict[str, Any]:
    """Validate one pseudonymous subject projection used in a snapshot digest."""
    label = f"subjects[{index}]"
    fields = {
        "schema_version",
        "subject_id",
        "kind",
        "identity_state",
        "canonical_subject_id",
        "aliases",
        "consent",
        "suppression",
        "identity_history",
        "audience_eligible",
        "eligibility_reason",
    }
    subject = _object(value, label, fields)
    assert_public_safe(subject, label)
    if subject["schema_version"] != 1:
        raise OptimizationError(f"{label} has an unsupported schema")
    references = [subject["subject_id"], subject["canonical_subject_id"]]
    aliases = subject["aliases"]
    if not isinstance(aliases, list):
        raise OptimizationError(f"{label}.aliases must be an array")
    references.extend(aliases)
    if any(not SUBJECT_REF_RE.fullmatch(str(item)) for item in references) or len(aliases) != len(set(aliases)):
        raise OptimizationError(f"{label} has invalid or duplicate subject references")
    if subject["subject_id"] not in aliases or subject["canonical_subject_id"] not in aliases:
        raise OptimizationError(f"{label} aliases do not include its subject lineage")
    if subject["kind"] not in SUBJECT_KINDS or subject["identity_state"] not in IDENTITY_STATES:
        raise OptimizationError(f"{label} has an unsupported identity state")
    if any(not isinstance(subject[field], list) for field in ("consent", "suppression", "identity_history")):
        raise OptimizationError(f"{label} history fields must be arrays")
    eligible = subject["audience_eligible"]
    reason = subject["eligibility_reason"]
    if not isinstance(eligible, bool) or reason not in ELIGIBILITY_REASONS or eligible != (reason == "eligible"):
        raise OptimizationError(f"{label} has inconsistent audience eligibility")
    if identity_is_uncertain(subject["identity_state"]) and (eligible or reason != "identity_ambiguous"):
        raise OptimizationError(f"{label} uncertain identity must be audience-ineligible")
    return subject


def canonical_subject_map(subjects: list[dict[str, Any]] | tuple[dict[str, Any], ...]) -> dict[str, str]:
    """Resolve every declared alias to one unambiguous canonical subject."""
    canonical_by_alias: dict[str, str] = {}
    subject_ids: set[str] = set()
    for subject in subjects:
        subject_id = str(subject["subject_id"])
        canonical = str(subject["canonical_subject_id"])
        if subject_id in subject_ids:
            raise OptimizationError("snapshot contains duplicate subject projections")
        subject_ids.add(subject_id)
        for alias in subject["aliases"]:
            alias_ref = str(alias)
            existing = canonical_by_alias.get(alias_ref)
            if existing is not None and existing != canonical:
                raise OptimizationError("subject alias resolves to conflicting canonical subjects")
            canonical_by_alias[alias_ref] = canonical
    return canonical_by_alias


def subject_uncertainty_map(
    subjects: list[dict[str, Any]] | tuple[dict[str, Any], ...],
) -> dict[str, bool]:
    """Resolve every alias to one consistent identity-uncertainty class."""
    canonical_subject_map(subjects)
    uncertain_by_alias: dict[str, bool] = {}
    for subject in subjects:
        uncertain = identity_is_uncertain(subject["identity_state"])
        for alias in subject["aliases"]:
            alias_ref = str(alias)
            if alias_ref in uncertain_by_alias and uncertain_by_alias[alias_ref] != uncertain:
                raise OptimizationError("subject alias has conflicting identity uncertainty")
            uncertain_by_alias[alias_ref] = uncertain
    return uncertain_by_alias


def validate_source_summary(value: Any, index: int) -> dict[str, Any]:
    """Validate one freshness and coverage summary consumed by report quality gates."""
    label = f"sources[{index}]"
    required = {
        "source",
        "account_ref",
        "status",
        "coverage",
        "missing_scopes",
        "last_observed_at",
        "stale_after_seconds",
        "lag_seconds",
        "stale",
        "unresolved_quarantine",
    }
    optional = {"adapter", "cursor_present", "last_success_at"}
    source = _object(value, label, required, optional)
    assert_public_safe(source, label)
    if source["source"] not in SOURCE_KINDS or source["status"] not in SOURCE_STATUSES:
        raise OptimizationError(f"{label} source or status is unsupported")
    require_alias(source["account_ref"], f"{label}.account_ref")
    optional_alias(source.get("adapter"), f"{label}.adapter")
    if source["coverage"] not in COMPLETENESS or not isinstance(source["missing_scopes"], list):
        raise OptimizationError(f"{label} coverage is invalid")
    missing_scopes = [require_alias(item, f"{label}.missing_scopes[]") for item in source["missing_scopes"]]
    if len(missing_scopes) != len(set(missing_scopes)):
        raise OptimizationError(f"{label}.missing_scopes must be unique")
    for field in ("last_observed_at", "last_success_at"):
        if source.get(field) is not None:
            parse_timestamp(source[field], f"{label}.{field}")
    _nonnegative_integer(source["stale_after_seconds"], f"{label}.stale_after_seconds")
    _nonnegative_integer(source["lag_seconds"], f"{label}.lag_seconds", nullable=True)
    _nonnegative_integer(source["unresolved_quarantine"], f"{label}.unresolved_quarantine")
    if not isinstance(source["stale"], bool) or (
        "cursor_present" in source and not isinstance(source["cursor_present"], bool)
    ):
        raise OptimizationError(f"{label} boolean state is invalid")
    return source
