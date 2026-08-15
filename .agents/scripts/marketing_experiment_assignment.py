#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Verified assignment loading and privacy-safe experiment population building."""

from __future__ import annotations

import copy
from dataclasses import dataclass
from typing import Any

from marketing_experiment_evidence import (
    AssignmentEvidence,
    load_assignment_evidence as load_assignment_evidence,
)
from marketing_experiment_assignment_grouping import (
    GroupingContext,
    contaminated_subjects,
    group_post_exposure_events,
    observed_labels,
    post_exposure_assignments,
    subject_variant,
)
from marketing_optimization_contract import (
    OptimizationError,
    OptimizationSnapshot,
    identity_is_uncertain,
    parse_datetime,
    require_list,
    require_object,
)
from marketing_optimization_snapshot_validation import canonical_subject_map


def _validate_snapshot_scope(snapshot: OptimizationSnapshot, data_policy: dict[str, Any]) -> None:
    """Reject snapshots broader than the preregistered campaign and account."""
    campaign_id = str(data_policy["campaign_id"])
    if any(event["scope"].get("campaign_id") != campaign_id for event in snapshot.events):
        raise OptimizationError("experiment snapshot contains events outside its requested campaign scope")
    account_ref = data_policy.get("account_ref")
    if account_ref is not None and (
        any(event["source"].get("account_ref") != account_ref for event in snapshot.events)
        or any(source.get("account_ref") != account_ref for source in snapshot.sources)
    ):
        raise OptimizationError("experiment snapshot contains evidence outside its requested account scope")


def _canonicalize_event(event: dict[str, Any], canonical_by_alias: dict[str, str]) -> dict[str, Any]:
    """Return an analysis-only event with its linked subject identity collapsed."""
    output = copy.deepcopy(event)
    subject_id = output["subject"].get("subject_id")
    if subject_id is not None:
        subject_ref = str(subject_id)
        output["subject"]["subject_id"] = canonical_by_alias.get(subject_ref, subject_ref)
    return output


def _canonicalize_evidence(
    evidence: AssignmentEvidence,
    canonical_by_alias: dict[str, str],
) -> AssignmentEvidence:
    """Collapse assignment aliases and reject duplicate canonical units."""
    assignments: dict[str, str] = {}
    assigned_at: dict[str, str] = {}
    for subject_ref, variant_id in evidence.assignments.items():
        canonical = canonical_by_alias.get(subject_ref, subject_ref)
        if canonical in assignments:
            raise OptimizationError("assignment snapshot contains duplicate canonical subjects")
        assignments[canonical] = variant_id
        assigned_at[canonical] = evidence.assigned_at[subject_ref]
    return AssignmentEvidence(
        evidence.assignment_ref,
        assignments,
        assigned_at,
        evidence.verified,
        evidence.reasons,
    )


@dataclass(frozen=True)
class ExperimentPopulation:
    """Aggregate-analysis population after contamination policy."""

    events_by_variant: dict[str, tuple[dict[str, Any], ...]]
    exposed_subjects: dict[str, frozenset[str]]
    excluded_subjects: frozenset[str]
    reasons: tuple[str, ...]
    invalid: bool
    assignment_verified: bool


def _within_window(event: dict[str, Any], started_at: str, ended_at: str, as_of: str) -> bool:
    """Return whether one event is observable inside the experiment window."""
    occurred = parse_datetime(event["event"]["occurred_at"], "experiment event occurred_at")
    upper = min(parse_datetime(ended_at, "experiment ended_at"), parse_datetime(as_of, "analysis as_of"))
    return parse_datetime(started_at, "experiment started_at") <= occurred <= upper


def build_population(
    snapshot: OptimizationSnapshot,
    definition: dict[str, Any],
    evidence: AssignmentEvidence,
) -> ExperimentPopulation:
    """Build variant populations without emitting subject-level rows."""
    data_policy = require_object(definition.get("data_policy"), "experiment data_policy")
    _validate_snapshot_scope(snapshot, data_policy)
    assignment = require_object(definition.get("assignment"), "experiment assignment")
    variant_ids = {str(item["variant_id"]) for item in require_list(definition.get("variants"), "variants")}
    canonical_by_alias = canonical_subject_map(snapshot.subjects)
    canonical_evidence = _canonicalize_evidence(evidence, canonical_by_alias)
    window_events = tuple(
        _canonicalize_event(event, canonical_by_alias)
        for event in snapshot.events
        if _within_window(event, data_policy["started_at"], data_policy["ended_at"], snapshot.as_of)
    )
    uncertain_subjects = {
        str(event["subject"]["subject_id"])
        for event in window_events
        if event["subject"].get("subject_id") is not None
        and identity_is_uncertain(event["subject"].get("identity_state"))
    }
    events = tuple(
        event
        for event in window_events
        if not identity_is_uncertain(event["subject"].get("identity_state"))
    )
    labels = observed_labels(events, variant_ids)
    exposure_metric = str(assignment.get("exposure_metric_id"))
    contaminated = contaminated_subjects(labels, canonical_evidence)
    contaminated.update(post_exposure_assignments(events, canonical_evidence, exposure_metric))
    invalid = bool(contaminated) and assignment.get("contamination_policy") == "mark_invalid"
    excluded = set(contaminated).union(uncertain_subjects)
    context = GroupingContext(variant_ids, excluded, labels, canonical_evidence, exposure_metric)
    grouped = group_post_exposure_events(events, context)
    reasons = set(canonical_evidence.reasons)
    if contaminated:
        reasons.add("assignment_contamination" if invalid else "crossovers_excluded")
    if uncertain_subjects:
        reasons.add("identity_ambiguity")
    unassigned = {
        str(event["subject"]["subject_id"])
        for event in events
        if event["subject"].get("subject_id") is not None
        and subject_variant(str(event["subject"]["subject_id"]), labels, canonical_evidence) is None
    }
    if unassigned:
        reasons.add("unassigned_subjects_excluded")
    if grouped.pre_exposure_excluded:
        reasons.add("pre_exposure_events_excluded")
    if grouped.unexposed_excluded:
        reasons.add("unexposed_events_excluded")
    return ExperimentPopulation(
        events_by_variant={key: tuple(value) for key, value in sorted(grouped.by_variant.items())},
        exposed_subjects={key: frozenset(value) for key, value in sorted(grouped.exposed.items())},
        excluded_subjects=frozenset(excluded),
        reasons=tuple(sorted(reasons)),
        invalid=invalid,
        assignment_verified=canonical_evidence.verified,
    )
