#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Post-exposure grouping for verified experiment assignments."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from marketing_experiment_evidence import AssignmentEvidence
from marketing_optimization_contract import parse_datetime


@dataclass(frozen=True)
class GroupedEvents:
    """Post-exposure aggregate inputs and exclusion signals."""

    by_variant: dict[str, list[dict[str, Any]]]
    exposed: dict[str, set[str]]
    pre_exposure_excluded: bool
    unexposed_excluded: bool


@dataclass(frozen=True)
class GroupingContext:
    """Assignment and exclusion state used while grouping events."""

    variant_ids: set[str]
    excluded: set[str]
    labels: dict[str, set[str]]
    evidence: AssignmentEvidence
    exposure_metric: str


def observed_labels(
    events: tuple[dict[str, Any], ...],
    variant_ids: set[str],
) -> dict[str, set[str]]:
    """Collect valid observed variant labels by pseudonymous subject."""
    labels: dict[str, set[str]] = {}
    for event in events:
        subject_id = event["subject"].get("subject_id")
        variant = event["scope"].get("dimensions", {}).get("experiment_variant")
        if subject_id is None or variant not in variant_ids:
            continue
        labels.setdefault(str(subject_id), set()).add(str(variant))
    return labels


def contaminated_subjects(
    labels: dict[str, set[str]],
    evidence: AssignmentEvidence,
) -> set[str]:
    """Detect crossovers and labels that contradict verified assignment."""
    contaminated = {subject_id for subject_id, variants in labels.items() if len(variants) > 1}
    if evidence.verified:
        contaminated.update(
            subject_id
            for subject_id, variants in labels.items()
            if subject_id in evidence.assignments and variants != {evidence.assignments[subject_id]}
        )
    return contaminated


def post_exposure_assignments(
    events: tuple[dict[str, Any], ...],
    evidence: AssignmentEvidence,
    exposure_metric: str,
) -> set[str]:
    """Reject exposures that predate their verified sticky assignment."""
    if not evidence.verified:
        return set()
    contaminated: set[str] = set()
    for event in events:
        subject_id = event["subject"].get("subject_id")
        if subject_id not in evidence.assigned_at or event["measurement"]["metric_id"] != exposure_metric:
            continue
        occurred = parse_datetime(event["event"]["occurred_at"], "exposure occurred_at")
        assigned = parse_datetime(evidence.assigned_at[str(subject_id)], "assignment assigned_at")
        if occurred < assigned:
            contaminated.add(str(subject_id))
    return contaminated


def subject_variant(
    subject_id: str,
    labels: dict[str, set[str]],
    evidence: AssignmentEvidence,
) -> str | None:
    """Use verified assignment or one unambiguous observational label."""
    if evidence.verified:
        return evidence.assignments.get(subject_id)
    observed = labels.get(subject_id, set())
    return next(iter(observed)) if len(observed) == 1 else None


def _first_exposures(
    events: tuple[dict[str, Any], ...],
    exposure_metric: str,
) -> dict[str, Any]:
    """Return the first observed exposure time for each pseudonymous subject."""
    first: dict[str, Any] = {}
    for event in events:
        subject_id = event["subject"].get("subject_id")
        if subject_id is None or event["measurement"]["metric_id"] != exposure_metric:
            continue
        occurred = parse_datetime(event["event"]["occurred_at"], "exposure occurred_at")
        current = first.get(str(subject_id))
        if current is None or occurred < current:
            first[str(subject_id)] = occurred
    return first


def group_post_exposure_events(
    events: tuple[dict[str, Any], ...],
    context: GroupingContext,
) -> GroupedEvents:
    """Group only events observed on or after each subject's first exposure."""
    first_exposures = _first_exposures(events, context.exposure_metric)
    by_variant: dict[str, list[dict[str, Any]]] = {variant_id: [] for variant_id in context.variant_ids}
    exposed: dict[str, set[str]] = {variant_id: set() for variant_id in context.variant_ids}
    pre_exposure_excluded = False
    unexposed_excluded = False
    for event in events:
        subject_id = event["subject"].get("subject_id")
        if subject_id is None or subject_id in context.excluded:
            continue
        subject_ref = str(subject_id)
        variant = subject_variant(subject_ref, context.labels, context.evidence)
        if variant is None:
            continue
        first_exposure = first_exposures.get(subject_ref)
        if first_exposure is None:
            unexposed_excluded = True
            continue
        occurred = parse_datetime(event["event"]["occurred_at"], "experiment event occurred_at")
        if occurred < first_exposure:
            pre_exposure_excluded = True
            continue
        by_variant[variant].append(event)
        if event["measurement"]["metric_id"] == context.exposure_metric:
            exposed[variant].add(subject_ref)
    return GroupedEvents(by_variant, exposed, pre_exposure_excluded, unexposed_excluded)
