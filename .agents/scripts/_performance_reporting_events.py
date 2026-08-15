"""Normalized event projections for performance reporting."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from performance_contract import decimal_wire


@dataclass(frozen=True)
class EventQuery:
    history: bool = False
    source: str | None = None
    account_ref: str | None = None
    campaign_id: str | None = None
    now_epoch: int | None = None

    @classmethod
    def from_options(cls, options: dict[str, Any]) -> "EventQuery":
        allowed = {"history", "source", "account_ref", "campaign_id", "now_epoch"}
        unknown = set(options) - allowed
        if unknown:
            raise TypeError(f"unknown event record options: {sorted(unknown)}")
        return cls(**options)


def _subject_projection(row: Any, subjects: dict[str, dict[str, Any]]) -> tuple[object, str, dict[str, Any]]:
    subject_id = row["subject_id"]
    if subject_id is None:
        return None, str(row["identity_state"]), {"audience_eligible": False, "eligibility_reason": "aggregate"}
    subject = next((item for item in subjects.values() if str(subject_id) in item["aliases"]), None)
    canonical = subject["subject_id"] if subject else str(subject_id)
    state = subject["identity_state"] if subject else str(row["identity_state"])
    governance = {
        "audience_eligible": bool(subject and subject["audience_eligible"]),
        "eligibility_reason": subject["eligibility_reason"] if subject else "consent_unknown",
    }
    return canonical, state, governance


def _source_record(row: Any, state: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": str(row["source"]), "account_ref": str(row["account_ref"]),
        "revision": int(row["revision"]), "observed_at": str(row["observed_at"]),
        "recorded_at": str(row["recorded_at"]),
        "source_observed_at": str(row["source_observed_at"]) if row["source_observed_at"] is not None else None,
        "source_recorded_at": str(row["source_recorded_at"]) if row["source_recorded_at"] is not None else None,
        "evidence_ref": str(row["evidence_ref"]), "coverage": state["coverage"],
        "missing_scopes": state["missing_scopes"],
    }


def _scope_record(row: Any) -> dict[str, Any]:
    fields = ("campaign_id", "channel", "creative_id", "touchpoint_id", "outcome_id")
    return {**{field: row[field] for field in fields}, "dimensions": json.loads(str(row["dimensions_json"]))}


def _measurement_record(row: Any) -> dict[str, Any]:
    return {
        "metric_id": str(row["metric_id"]), "value": decimal_wire(str(row["value_text"])),
        "unit": str(row["unit"]), "aggregation": str(row["aggregation"]),
        "currency": row["currency"], "period_start": row["period_start"], "period_end": row["period_end"],
    }


def _event_record(reporting: Any, row: Any, state: dict[str, Any], subjects: dict[str, dict[str, Any]]) -> dict[str, Any]:
    canonical, identity_state, governance = _subject_projection(row, subjects)
    confidence = reporting._effective_confidence(str(row["confidence"]), state["status"], str(row["completeness"]), identity_state)
    return {
        "schema_version": 1, "record_ref": str(row["record_ref"]), "event_ref": str(row["event_ref"]),
        "source": _source_record(row, state),
        "event": {"type": str(row["event_type"]), "occurred_at": str(row["occurred_at"]), "correction_of": row["correction_ref"]},
        "subject": {"subject_id": canonical, "kind": str(row["subject_kind"]), "identity_state": identity_state},
        "scope": _scope_record(row), "measurement": _measurement_record(row),
        "quality": {
            "confidence": str(row["confidence"]), "effective_confidence": confidence,
            "completeness": str(row["completeness"]), "source_type": str(row["source_type"]),
            "collected_by": str(row["collected_by"]), "evidence_ref": str(row["evidence_ref"]),
        },
        "governance": governance,
    }


def event_records(reporting: Any, query: EventQuery) -> list[dict[str, Any]]:
    """Return schema-valid pseudonymous event records."""
    source_state = {(row["source"], row["account_ref"]): row for row in reporting._source_rows(query.now_epoch)}
    subjects = {row["subject_id"]: row for row in reporting.subject_records(query.now_epoch)}
    rows = reporting._effective_rows(history=query.history, source=query.source, account_ref=query.account_ref, campaign_id=query.campaign_id)
    return [_event_record(reporting, row, source_state[(str(row["source"]), str(row["account_ref"]))], subjects) for row in rows]
