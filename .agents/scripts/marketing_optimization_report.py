#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Freshness-aware aggregate marketing performance report projections."""

from __future__ import annotations

import re
from decimal import Decimal
from typing import Any

from marketing_experiment_definition import register_experiment
from marketing_experiment_evidence import experiment_run_reference
from marketing_attribution_validation import validate_attribution_artifact
from marketing_optimization_contract import (
    MINIMUM_AGGREGATE_CELL_SIZE,
    OptimizationError,
    OptimizationSnapshot,
    assert_public_safe,
    divide,
    minimum_confidence,
    parse_datetime,
    require_integer,
    require_list,
    require_object,
    source_is_stale,
    snapshot_quality,
    typed_reference,
    wire_number,
)
from marketing_optimization_evidence import validate_report_evidence_scopes, validate_scope_binding
from marketing_optimization_validation_common import REPORT_CAUSAL_STATEMENT
from marketing_report_validation import validate_report_artifact
from marketing_report_aggregation import aggregate_performance

EXPERIMENT_REF_RE = re.compile(r"^mkt-experiment-v1:[a-f0-9]{64}$")
EXPERIMENT_RUN_REF_RE = re.compile(r"^mkt-experiment-run-v1:[a-f0-9]{64}$")
FORBIDDEN_SIDE_EFFECTS = [
    "publish",
    "message",
    "spend",
    "retarget",
    "change_offer",
    "mutate_account",
    "export_audience",
]


def _freshness(reasons: list[str], source_count: int) -> str:
    """Render one conservative report freshness state."""
    if source_count == 0 or "unknown_source_freshness" in reasons:
        return "unknown"
    if "stale_source" in reasons:
        return "stale"
    if any(
        reason in {"partial_coverage", "unknown_coverage", "missing_scopes", "insufficient_event_confidence"}
        for reason in reasons
    ):
        return "partial"
    return "fresh"


def _evidence_coverage(snapshot: OptimizationSnapshot) -> int | str | None:
    """Return the lowest complete fraction across sources and events."""
    if not snapshot.sources:
        return None
    complete = sum(
        int(source.get("coverage") == "complete" and not source_is_stale(snapshot.as_of, source))
        for source in snapshot.sources
    )
    values = [divide(Decimal(complete), Decimal(len(snapshot.sources)))]
    if snapshot.events:
        complete_events = sum(int(event["quality"]["completeness"] == "complete") for event in snapshot.events)
        values.append(divide(Decimal(complete_events), Decimal(len(snapshot.events))))
    return wire_number(min(value for value in values if value is not None))


def _scope(snapshot: OptimizationSnapshot, field: str, source: bool = False) -> str | None:
    """Return a scope value only when all effective events agree."""
    container = "source" if source else "scope"
    values = {event[container].get(field) for event in snapshot.events if event[container].get(field)}
    return next(iter(values)) if len(values) == 1 else None


def _validate_snapshot_binding(
    run: dict[str, Any],
    provenance: dict[str, Any],
    snapshot: OptimizationSnapshot,
    label: str,
) -> None:
    """Require evidence to come from the report's exact source snapshot."""
    if run.get("input_snapshot_sha256") != snapshot.digest or run.get("as_of") != snapshot.as_of:
        raise OptimizationError(f"{label} does not match the report snapshot")
    if snapshot.digest not in provenance.get("source_snapshot_refs", []):
        raise OptimizationError(f"{label} provenance does not include the report snapshot")


def _attribution_summary(document: dict[str, Any], snapshot: OptimizationSnapshot) -> dict[str, Any]:
    """Project one validated aggregate attribution into report evidence."""
    reference = validate_attribution_artifact(document)
    run = require_object(document.get("run"), "attribution run")
    provenance = require_object(document.get("provenance"), "attribution provenance")
    scope = require_object(document.get("scope"), "attribution scope")
    _validate_snapshot_binding(run, provenance, snapshot, "attribution")
    validate_scope_binding(
        scope,
        _scope(snapshot, "account_ref", source=True),
        _scope(snapshot, "campaign_id"),
        "attribution",
    )
    if document.get("causal_assessment", {}).get("status") != "observational_only":
        raise OptimizationError("attribution evidence must remain observational")
    return {
        "attribution_ref": reference,
        "input_snapshot_sha256": run["input_snapshot_sha256"],
        "as_of": run["as_of"],
        "model": document["model"],
        "scope": scope,
        "window": document["window"],
        "run_status": document["run"]["status"],
        "outcomes": document["outcomes"],
        "costs": document["costs"],
        "allocations": document["allocations"],
        "coverage": document["coverage"],
        "data_confidence": document["uncertainty"]["data_confidence"],
        "uncertainty_reasons": document["uncertainty"]["reasons"],
        "causal_status": "observational_only",
    }


def _validate_causal_experiment(document: dict[str, Any], analysis: dict[str, Any]) -> None:
    """Reject causal labels without the verified randomized assignment boundary."""
    if analysis.get("causal_status") != "causal_supported":
        return
    assignment = require_object(document.get("assignment"), "experiment assignment")
    randomized = assignment.get("method") == "randomized"
    verified = assignment.get("verification") == "verified"
    sticky = assignment.get("sticky") is True
    referenced = assignment.get("snapshot_ref") is not None
    eligible = analysis.get("decision_eligible") is True
    supported = all((randomized, verified, sticky, referenced, eligible))
    if not supported:
        raise OptimizationError("causal experiment evidence lacks verified randomized assignment")


def _experiment_summary(document: dict[str, Any], snapshot: OptimizationSnapshot) -> dict[str, Any]:
    """Project one aggregate experiment look into report evidence."""
    registered = register_experiment(document)
    reference = str(registered.get("experiment_ref", ""))
    analysis = require_object(registered.get("analysis"), "experiment analysis")
    if not EXPERIMENT_REF_RE.fullmatch(reference):
        raise OptimizationError("report experiment input requires an analysed experiment")
    run_ref = str(analysis.get("run_ref", ""))
    if not EXPERIMENT_RUN_REF_RE.fullmatch(run_ref):
        raise OptimizationError("report experiment input has an invalid run reference")
    if experiment_run_reference(reference, analysis) != run_ref:
        raise OptimizationError("experiment run reference does not match its content")
    provenance = require_object(registered.get("provenance"), "experiment provenance")
    _validate_snapshot_binding(analysis, provenance, snapshot, "experiment")
    data_policy = require_object(registered.get("data_policy"), "experiment data policy")
    validate_scope_binding(
        data_policy,
        _scope(snapshot, "account_ref", source=True),
        _scope(snapshot, "campaign_id"),
        "experiment",
    )
    _validate_causal_experiment(registered, analysis)
    primary = registered["metrics"]["primary"]
    assignment = registered["assignment"]
    return {
        "experiment_ref": reference,
        "run_ref": run_ref,
        "input_snapshot_sha256": analysis["input_snapshot_sha256"],
        "as_of": analysis["as_of"],
        "experiment_id": registered["experiment_id"],
        "owner": registered["owner"],
        "scope": {
            "account_ref": data_policy["account_ref"],
            "campaign_id": data_policy["campaign_id"],
        },
        "window": {
            "started_at": data_policy["started_at"],
            "ended_at": data_policy["ended_at"],
        },
        "assignment": {
            "method": assignment["method"],
            "verification": assignment["verification"],
            "sticky": assignment["sticky"],
            "snapshot_ref": assignment["snapshot_ref"],
        },
        "analysis_status": analysis["status"],
        "causal_status": analysis["causal_status"],
        "decision_eligible": analysis["decision_eligible"],
        "winner_variant_id": analysis["winner_variant_id"],
        "primary_metric": primary,
        "variant_results": analysis["variant_results"],
        "comparisons": analysis["comparisons"],
        "guardrails": analysis["guardrails"],
        "insufficient_reasons": analysis["insufficient_reasons"],
    }


def _report_confidence(
    attributions: list[dict[str, Any]],
    experiments: list[dict[str, Any]],
    quality_reasons: list[str],
    snapshot: OptimizationSnapshot,
) -> str:
    """Combine evidence confidence while capping any degraded snapshot."""
    values = [str(item["data_confidence"]) for item in attributions]
    values.extend("verified" if item["causal_status"] == "causal_supported" else "low" for item in experiments)
    values.extend(str(event["quality"]["effective_confidence"]) for event in snapshot.events)
    confidence = minimum_confidence(values) if values else "high"
    return minimum_confidence([confidence, "medium"]) if quality_reasons else confidence


def _build_report_from_resolved_evidence(
    snapshot: OptimizationSnapshot,
    attributions: list[dict[str, Any]],
    experiments: list[dict[str, Any]],
    minimum_cell_size: int,
) -> dict[str, Any]:
    """Build a report from evidence already resolved by the immutable registry."""
    require_integer(
        minimum_cell_size,
        "report minimum_cell_size",
        MINIMUM_AGGREGATE_CELL_SIZE,
        1000000,
    )
    performance_rows = aggregate_performance(snapshot, minimum_cell_size)
    attribution_sections = [_attribution_summary(item, snapshot) for item in attributions]
    experiment_sections = [_experiment_summary(item, snapshot) for item in experiments]
    quality_reasons, missing_scopes = snapshot_quality(snapshot)
    suppressed_cells = sum(int(item["suppressed"]) for item in performance_rows)
    combined_reasons = set(quality_reasons)
    for attribution in attribution_sections:
        combined_reasons.update(str(reason) for reason in attribution["uncertainty_reasons"])
        if attribution["run_status"] != "complete":
            combined_reasons.add(f"attribution_{attribution['run_status']}")
    for experiment in experiment_sections:
        combined_reasons.update(str(reason) for reason in experiment["insufficient_reasons"])
        if experiment["analysis_status"] != "complete":
            combined_reasons.add(f"experiment_{experiment['analysis_status']}")
    if suppressed_cells:
        combined_reasons.add("privacy_suppressed_cells")
    if not performance_rows:
        combined_reasons.add("no_performance_evidence")
    reasons = sorted(combined_reasons)
    status = "insufficient_evidence" if not performance_rows else "partial" if reasons else "complete"
    first_event = min(
        snapshot.events,
        key=lambda event: (
            parse_datetime(event["event"]["occurred_at"], "report event occurred_at"),
            event["record_ref"],
        ),
        default=None,
    )
    body: dict[str, Any] = {
        "schema": "aidevops.marketing-optimization-report/v1",
        "schema_version": 1,
        "run": {
            "input_snapshot_sha256": snapshot.digest,
            "as_of": snapshot.as_of,
            "generated_at": snapshot.as_of,
            "period_start": first_event["event"]["occurred_at"] if first_event is not None else None,
            "period_end": snapshot.as_of,
            "status": status,
        },
        "scope": {
            "account_ref": _scope(snapshot, "account_ref", source=True),
            "campaign_id": _scope(snapshot, "campaign_id"),
        },
        "performance": {
            "rows": performance_rows,
            "categories": sorted({str(item["category"]) for item in performance_rows}),
        },
        "attributions": attribution_sections,
        "experiments": experiment_sections,
        "quality": {
            "minimum_cell_size": minimum_cell_size,
            "freshness": _freshness(quality_reasons, len(snapshot.sources)),
            "coverage": _evidence_coverage(snapshot),
            "data_confidence": _report_confidence(attribution_sections, experiment_sections, reasons, snapshot),
            "reasons": reasons,
            "missing_scopes": missing_scopes,
            "suppressed_cells": suppressed_cells,
        },
        "interpretation": {
            "causal_statement": REPORT_CAUSAL_STATEMENT,
            "distinguishes_business_outcomes": True,
            "roi_requires_compatible_currency": True,
            "payback_status": "not_calculated_without_valid_time_to_recovery_evidence",
        },
        "authority": {
            "interpretation_only": True,
            "owner_review_required": True,
            "forbidden_side_effects": FORBIDDEN_SIDE_EFFECTS,
        },
        "provenance": {
            "source_snapshot_refs": [snapshot.digest],
            "attribution_refs": sorted(item["attribution_ref"] for item in attribution_sections),
            "experiment_refs": sorted(item["run_ref"] for item in experiment_sections),
        },
    }
    body["report_ref"] = typed_reference("mkt-report-v1", body)
    assert_public_safe(body, "marketing optimization report")
    return body


def validate_report_document(report: dict[str, Any]) -> None:
    """Validate report integrity and evidence bindings before recommendation use."""
    validate_report_artifact(report)
    run = require_object(report.get("run"), "report run")
    provenance = require_object(report.get("provenance"), "report provenance")
    snapshot_ref = run.get("input_snapshot_sha256")
    if provenance.get("source_snapshot_refs") != [snapshot_ref]:
        raise OptimizationError("report snapshot provenance is inconsistent")
    attributions = [require_object(item, "report attribution") for item in require_list(report.get("attributions"), "report attributions")]
    experiments = [require_object(item, "report experiment") for item in require_list(report.get("experiments"), "report experiments")]
    if any(item.get("input_snapshot_sha256") != snapshot_ref for item in attributions + experiments):
        raise OptimizationError("report evidence does not share one source snapshot")
    if sorted(item.get("attribution_ref") for item in attributions) != provenance.get("attribution_refs"):
        raise OptimizationError("report attribution provenance is inconsistent")
    if sorted(item.get("run_ref") for item in experiments) != provenance.get("experiment_refs"):
        raise OptimizationError("report experiment provenance is inconsistent")
    report_scope = require_object(report.get("scope"), "report scope")
    validate_report_evidence_scopes(report_scope, attributions + experiments)
    for item in experiments:
        _validate_causal_experiment(item, item)
    authority = require_object(report.get("authority"), "report authority")
    interpretation_only = authority.get("interpretation_only") is True
    safe_boundary = set(authority.get("forbidden_side_effects", [])) == set(FORBIDDEN_SIDE_EFFECTS)
    if not interpretation_only or not safe_boundary:
        raise OptimizationError("report authority boundary is invalid")


def render_report_markdown(report: dict[str, Any]) -> str:
    """Render a concise review draft from an already-safe aggregate report."""
    lines = [
        "# Marketing optimization report",
        "",
        f"Status: {report['run']['status']}",
        f"As of: {report['run']['as_of']}",
        f"Freshness: {report['quality']['freshness']}",
        f"Coverage: {report['quality']['coverage']}",
        "",
        "Observational performance and attribution do not establish causal growth.",
        "",
        "## Aggregate performance",
        "",
        "| Category | Metric | Channel | Creative | Value | Unit |",
        "|---|---|---|---|---:|---|",
    ]
    for row in report["performance"]["rows"]:
        value = "suppressed" if row["suppressed"] else str(row["value"])
        lines.append(
            f"| {row['category']} | {row['metric_id']} | {row['channel'] or '-'} | "
            f"{row['creative_id'] or '-'} | {value} | {row['unit']} |"
        )
    lines.extend(["", "## Attribution", ""])
    for item in report["attributions"]:
        lines.append(
            f"- {item['model']['id']}: {item['scope']['outcome_metric_id']} "
            f"({item['run_status']}, observational only)"
        )
    lines.extend(["", "## Experiments", ""])
    for item in report["experiments"]:
        winner = item["winner_variant_id"] or "no eligible winner"
        lines.append(f"- {item['experiment_id']}: {item['analysis_status']}; {winner}")
    lines.extend(["", "## Caveats", ""])
    lines.extend(f"- {reason}" for reason in report["quality"]["reasons"])
    return "\n".join(lines).rstrip() + "\n"
