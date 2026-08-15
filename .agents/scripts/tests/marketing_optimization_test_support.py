#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Synthetic aggregate-fixture helpers for marketing optimization tests."""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from marketing_attribution import AttributionRequest
from marketing_optimization_contract import (
    MINIMUM_AGGREGATE_CELL_SIZE,
    MINIMUM_EXPERIMENT_CONVERSIONS_PER_VARIANT,
    MINIMUM_EXPERIMENT_RUNTIME_SECONDS,
    MINIMUM_EXPERIMENT_SAMPLE_PER_VARIANT,
    typed_reference,
)

AS_OF = "2026-08-15T00:00:00Z"
ACCOUNT = "fixture-account"
CAMPAIGN = "growth-campaign"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "marketing-optimization"


def _reference(prefix: str, label: str) -> str:
    """Return one valid deterministic typed reference."""
    return f"{prefix}:{hashlib.sha256(label.encode('utf-8')).hexdigest()}"


def aggregate_snapshot_document(
    document: dict[str, Any],
    population: int = MINIMUM_AGGREGATE_CELL_SIZE,
) -> dict[str, Any]:
    """Replicate one synthetic subject journey into a privacy-safe aggregate."""
    source = json.loads(json.dumps(document))
    original_events = list(source["events"])
    original_subjects = list(source["subjects"])
    if len(original_subjects) != 1:
        raise AssertionError("aggregate fixture requires exactly one source subject")
    original_subject_id = str(original_subjects[0]["subject_id"])
    events: list[dict[str, Any]] = []
    subjects: list[dict[str, Any]] = []
    for replica in range(population):
        subject_id = _reference("mkt-subj-v1", f"aggregate-subject-{replica}")
        event_refs = {
            str(event["event_ref"]): _reference("mkt-event-v1", f"aggregate-event-{replica}-{position}")
            for position, event in enumerate(original_events)
        }
        for position, value in enumerate(original_events):
            event = json.loads(json.dumps(value))
            event["record_ref"] = _reference("mkt-record-v1", f"aggregate-record-{replica}-{position}")
            event["event_ref"] = event_refs[str(value["event_ref"])]
            evidence_ref = _reference("mkt-evidence-v1:sha256", f"aggregate-evidence-{replica}-{position}")
            event["source"]["evidence_ref"] = evidence_ref
            event["quality"]["evidence_ref"] = evidence_ref
            if event["subject"]["subject_id"] == original_subject_id:
                event["subject"]["subject_id"] = subject_id
            for field in ("outcome_id", "touchpoint_id"):
                if event["scope"][field] is not None:
                    event["scope"][field] = f"{event['scope'][field]}-{replica}"
            correction_of = event["event"].get("correction_of")
            if correction_of in event_refs:
                event["event"]["correction_of"] = event_refs[str(correction_of)]
            events.append(event)
        subject = json.loads(json.dumps(original_subjects[0]))
        subject["subject_id"] = subject_id
        subject["canonical_subject_id"] = subject_id
        subject["aliases"] = [subject_id]
        subjects.append(subject)
    source["events"] = events
    source["subjects"] = subjects
    return source


def load_fixture(name: str) -> dict[str, object]:
    """Load one committed, synthetic optimization fixture."""
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def reference(prefix: str, digit: str) -> str:
    """Return one stable synthetic typed reference."""
    return f"{prefix}:{digit * 64}"


def normalized_event(
    digit: str,
    event_type: str,
    occurred_at: str,
    *,
    subject_id: str | None = None,
) -> dict[str, object]:
    """Build one schema-shaped normalized event without provider data."""
    metric_id, unit = {
        "engagement": ("marketing.engagement.total", "engagement"),
        "impression": ("marketing.impressions.total", "impression"),
        "visit": ("marketing.visits.total", "visit"),
    }.get(event_type, ("marketing.conversions.total", "conversion"))
    return {
        "schema_version": 1,
        "record_ref": reference("mkt-record-v1", digit),
        "event_ref": reference("mkt-event-v1", digit),
        "source": {
            "kind": "normalized",
            "account_ref": ACCOUNT,
            "revision": 1,
            "observed_at": occurred_at,
            "recorded_at": occurred_at,
            "source_observed_at": occurred_at,
            "source_recorded_at": occurred_at,
            "evidence_ref": reference("mkt-evidence-v1:sha256", digit),
            "coverage": "complete",
            "missing_scopes": [],
        },
        "event": {"type": event_type, "occurred_at": occurred_at, "correction_of": None},
        "subject": {
            "subject_id": subject_id,
            "kind": "lead" if subject_id else "aggregate",
            "identity_state": "isolated" if subject_id else "not_applicable",
        },
        "scope": {
            "campaign_id": CAMPAIGN,
            "channel": "search",
            "creative_id": "creative-a",
            "touchpoint_id": "touch-a" if event_type in {"engagement", "visit"} else None,
            "outcome_id": "outcome-a" if event_type not in {"engagement", "visit"} else None,
            "dimensions": {},
        },
        "measurement": {
            "metric_id": metric_id,
            "value": 1,
            "unit": unit,
            "aggregation": "sum",
            "currency": None,
        },
        "quality": {
            "confidence": "high",
            "effective_confidence": "high",
            "completeness": "complete",
            "source_type": "fixture",
            "collected_by": "synthetic-fixture",
            "evidence_ref": reference("mkt-evidence-v1:sha256", digit),
        },
        "governance": {"audience_eligible": False, "eligibility_reason": "consent_unknown"},
    }


def subject(digit: str) -> dict[str, object]:
    """Build one pseudonymous subject projection."""
    subject_id = reference("mkt-subj-v1", digit)
    return {
        "schema_version": 1,
        "subject_id": subject_id,
        "kind": "lead",
        "identity_state": "isolated",
        "canonical_subject_id": subject_id,
        "aliases": [subject_id],
        "consent": [],
        "suppression": [],
        "identity_history": [],
        "audience_eligible": False,
        "eligibility_reason": "consent_unknown",
    }


def snapshot_document() -> dict[str, object]:
    """Return one deterministic fixture with an out-of-bound future event."""
    return load_fixture("sparse-journey.json")


def analysis_document() -> dict[str, object]:
    """Return a mature, fresh snapshot for deterministic analysis tests."""
    document = snapshot_document()
    document["events"] = document["events"][:2]
    document["sources"][0]["last_observed_at"] = AS_OF
    document["sources"][0]["stale"] = False
    document["sources"][0]["lag_seconds"] = 0
    return document


def mark_uncertain_identities(document: dict[str, object], identity_state: str) -> dict[str, object]:
    """Mark every synthetic subject as non-distinct identity evidence."""
    for event in document["events"]:
        event["subject"]["identity_state"] = identity_state
        event["governance"] = {
            "audience_eligible": False,
            "eligibility_reason": "identity_ambiguous",
        }
    for item in document["subjects"]:
        item["identity_state"] = identity_state
        item["audience_eligible"] = False
        item["eligibility_reason"] = "identity_ambiguous"
    return document


def aggregate_analysis_document() -> dict[str, object]:
    """Return a visible aggregate while preserving the sparse source fixture."""
    return aggregate_snapshot_document(analysis_document())


def attribution_request(**overrides: object) -> AttributionRequest:
    """Return one compact request at the immutable privacy floor."""
    values: dict[str, object] = {
        "outcome_metric_id": "marketing.conversions.total",
        "model": "last_touch",
        "lookback_seconds": 30 * 86400,
        "refund_maturity_seconds": 0,
        "minimum_cell_size": MINIMUM_AGGREGATE_CELL_SIZE,
    }
    values.update(overrides)
    return AttributionRequest(**values)


def hashed_reference(prefix: str, label: str) -> str:
    """Return a valid deterministic typed reference for larger fixtures."""
    return f"{prefix}:{hashlib.sha256(label.encode('utf-8')).hexdigest()}"


def experiment_event(index: int, spec: dict[str, object]) -> dict[str, object]:
    """Build one subject-level experiment event from compact fixture fields."""
    event_type = str(spec["event_type"])
    metric_id = str(spec["metric_id"])
    subject_id = str(spec["subject_id"])
    variant_id = str(spec["variant_id"])
    event = normalized_event(
        "1",
        event_type,
        str(spec.get("occurred_at", "2026-08-03T12:00:00Z")),
        subject_id=subject_id,
    )
    event["record_ref"] = hashed_reference("mkt-record-v1", f"record-{index}")
    event["event_ref"] = hashed_reference("mkt-event-v1", f"event-{index}")
    event["source"]["evidence_ref"] = hashed_reference("mkt-evidence-v1:sha256", f"evidence-{index}")
    event["quality"]["evidence_ref"] = event["source"]["evidence_ref"]
    event["scope"]["dimensions"]["experiment_variant"] = variant_id
    event["measurement"].update(
        {
            "metric_id": metric_id,
            "value": spec.get("value", 1),
            "unit": spec.get("unit", "conversion"),
            "currency": None,
        }
    )
    return event


def experiment_subject(subject_id: str) -> dict[str, object]:
    """Build one complete subject record for experiment fixtures."""
    return {
        "schema_version": 1,
        "subject_id": subject_id,
        "kind": "lead",
        "identity_state": "isolated",
        "canonical_subject_id": subject_id,
        "aliases": [subject_id],
        "consent": [],
        "suppression": [],
        "identity_history": [],
        "audience_eligible": False,
        "eligibility_reason": "consent_unknown",
    }


def experiment_fixture(
    options: dict[str, int] | None = None,
) -> tuple[dict[str, object], dict[str, object], dict[str, object]]:
    """Build balanced or deliberately adversarial experiment fixtures."""
    fixture = load_fixture("verified-control-experiment.json")
    settings = dict(fixture["settings"])
    settings.update(options or {})
    variants = (("control", settings["control_subjects"]), ("treatment", settings["treatment_subjects"]))
    assignments: list[dict[str, object]] = []
    events: list[dict[str, object]] = []
    subjects: list[dict[str, object]] = []
    index = 0
    for variant_id, count in variants:
        for position in range(count):
            subject_id = hashed_reference("mkt-subj-v1", f"{variant_id}-{position}")
            assignments.append(
                {"unit_ref": subject_id, "variant_id": variant_id, "assigned_at": "2026-08-01T00:00:00Z"}
            )
            subjects.append(experiment_subject(subject_id))
            events.append(
                experiment_event(
                    index,
                    {
                        "event_type": "impression",
                        "metric_id": "marketing.experiment.exposures",
                        "unit": "impression",
                        "subject_id": subject_id,
                        "variant_id": variant_id,
                        "occurred_at": "2026-08-02T12:00:00Z",
                    },
                )
            )
            index += 1
            if position < settings[f"{variant_id}_conversions"]:
                events.append(
                    experiment_event(
                        index,
                        {
                            "event_type": "conversion",
                            "metric_id": "marketing.conversions.total",
                            "unit": "conversion",
                            "subject_id": subject_id,
                            "variant_id": variant_id,
                        },
                    )
                )
                index += 1
            has_positive_guardrail = variant_id == "treatment" and position < settings["treatment_guardrails"]
            if has_positive_guardrail:
                events.append(
                    experiment_event(
                        index,
                        {
                            "event_type": "unsubscribe",
                            "metric_id": "marketing.unsubscribes.total",
                            "unit": "unsubscribe",
                            "subject_id": subject_id,
                            "variant_id": variant_id,
                        },
                    )
                )
                index += 1
            elif position < MINIMUM_AGGREGATE_CELL_SIZE:
                events.append(
                    experiment_event(
                        index,
                        {
                            "event_type": "unsubscribe",
                            "metric_id": "marketing.unsubscribes.total",
                            "unit": "unsubscribe",
                            "value": 0,
                            "subject_id": subject_id,
                            "variant_id": variant_id,
                        },
                    )
                )
                index += 1
    assignment: dict[str, object] = {
        "schema": "aidevops.marketing-assignment-snapshot/v1",
        "experiment_id": "landing-page-test",
        "definition_version": 1,
        "generated_at": "2026-08-01T00:00:00Z",
        "assignments": assignments,
    }
    assignment["assignment_ref"] = typed_reference("mkt-assignment-v1:sha256", assignment)
    definition = dict(fixture["definition"])
    definition["assignment"]["snapshot_ref"] = assignment["assignment_ref"]
    snapshot: dict[str, object] = {
        "schema": "aidevops.marketing-optimization-snapshot/v1",
        "as_of": AS_OF,
        "events": events,
        "subjects": subjects,
        "sources": [
            {
                "source": "normalized",
                "account_ref": ACCOUNT,
                "status": "ready",
                "coverage": "complete",
                "missing_scopes": [],
                "last_observed_at": "2026-08-03T12:00:00Z",
                "stale_after_seconds": 30 * 86400,
                "lag_seconds": 0,
                "stale": False,
                "unresolved_quarantine": 0,
            }
        ],
    }
    return definition, assignment, snapshot


def future_cli_experiment_fixture() -> tuple[dict[str, object], dict[str, object], dict[str, object]]:
    """Return an experiment whose trusted registration boundary is still open."""
    definition, assignment, snapshot = experiment_fixture()
    now = datetime.now(timezone.utc).replace(microsecond=0)
    start = now + timedelta(days=1)
    exposure = start + timedelta(days=1)
    outcome = start + timedelta(days=2)
    end = start + timedelta(days=9)
    as_of = end + timedelta(days=5)

    def stamp(value: datetime) -> str:
        return value.isoformat().replace("+00:00", "Z")

    definition["hypothesis"]["preregistered_at"] = stamp(now)
    definition["data_policy"]["started_at"] = stamp(start)
    definition["data_policy"]["ended_at"] = stamp(end)
    assignment["generated_at"] = stamp(now)
    for row in assignment["assignments"]:
        row["assigned_at"] = stamp(start)
    assignment.pop("assignment_ref")
    assignment["assignment_ref"] = typed_reference("mkt-assignment-v1:sha256", assignment)
    definition["assignment"]["snapshot_ref"] = assignment["assignment_ref"]
    for event in snapshot["events"]:
        occurred_at = exposure if event["measurement"]["metric_id"] == "marketing.experiment.exposures" else outcome
        timestamp = stamp(occurred_at)
        event["event"]["occurred_at"] = timestamp
        for field in ("observed_at", "recorded_at", "source_observed_at", "source_recorded_at"):
            event["source"][field] = timestamp
    snapshot["as_of"] = stamp(as_of)
    snapshot["sources"][0]["last_observed_at"] = stamp(outcome)
    return definition, assignment, snapshot
