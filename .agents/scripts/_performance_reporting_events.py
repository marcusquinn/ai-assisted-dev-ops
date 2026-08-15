"""Normalized event projections for performance reporting."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from performance_contract import PerformanceContractError, decimal_wire, timestamp_epoch


@dataclass(frozen=True)
class EventQuery:
    history: bool = False
    source: str | None = None
    account_ref: str | None = None
    campaign_id: str | None = None
    now_epoch: float | None = None

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
    uncertain = state in {"ambiguous", "split"}
    governance = (
        {"audience_eligible": False, "eligibility_reason": "identity_ambiguous"}
        if uncertain
        else {
            "audience_eligible": bool(subject and subject["audience_eligible"]),
            "eligibility_reason": subject["eligibility_reason"] if subject else "consent_unknown",
        }
    )
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


def _effective_event_semantics(reporting: Any, row: Any, now_epoch: float | None) -> tuple[str, str]:
    """Resolve a correction to its target's type and economic occurrence time."""
    event_type = str(row["event_type"])
    occurred_at = str(row["occurred_at"])
    target_ref = row["correction_ref"]
    seen: set[str] = set()
    while target_ref is not None:
        reference = str(target_ref)
        if reference in seen:
            raise PerformanceContractError("event correction chain contains a cycle")
        seen.add(reference)
        candidates = list(
            reporting.connection.execute(
                "SELECT event_type,correction_ref,occurred_at,recorded_at,revision "
                "FROM events WHERE source=? AND account_ref=? AND event_ref=?",
                (str(row["source"]), str(row["account_ref"]), reference),
            )
        )
        if now_epoch is not None:
            candidates = [
                candidate
                for candidate in candidates
                if timestamp_epoch(str(candidate["occurred_at"])) <= now_epoch
                and timestamp_epoch(str(candidate["recorded_at"])) <= now_epoch
            ]
        if not candidates:
            raise PerformanceContractError("event correction target is unavailable")
        target = max(candidates, key=lambda candidate: int(candidate["revision"]))
        event_type = str(target["event_type"])
        occurred_at = str(target["occurred_at"])
        target_ref = target["correction_ref"]
    return event_type, occurred_at


def _latest_events(rows: list[Any]) -> dict[tuple[str, str, str], Any]:
    """Index the highest stored revision for each event identity."""
    latest: dict[tuple[str, str, str], Any] = {}
    for row in rows:
        key = (str(row["source"]), str(row["account_ref"]), str(row["event_ref"]))
        if key not in latest or int(row["revision"]) > int(latest[key]["revision"]):
            latest[key] = row
    return latest


def current_events(rows: list[Any]) -> list[Any]:
    """Return effective rows after rejecting cyclic correction chains."""
    latest = _latest_events(rows)
    for start in latest:
        current = start
        seen: set[tuple[str, str, str]] = set()
        while current in latest and latest[current]["correction_ref"] is not None:
            if current in seen:
                raise PerformanceContractError("event correction chain contains a cycle")
            seen.add(current)
            row = latest[current]
            current = (
                str(row["source"]),
                str(row["account_ref"]),
                str(row["correction_ref"]),
            )
        if current not in latest:
            raise PerformanceContractError("event correction target is unavailable")
    correction_refs = {
        str(row["correction_ref"])
        for row in latest.values()
        if row["correction_ref"] is not None
    }
    return [
        row
        for row in rows
        if latest.get((str(row["source"]), str(row["account_ref"]), str(row["event_ref"]))) is row
        and str(row["event_ref"]) not in correction_refs
    ]


def _event_record(
    reporting: Any,
    row: Any,
    state: dict[str, Any],
    subjects: dict[str, dict[str, Any]],
    query: EventQuery,
) -> dict[str, Any]:
    """Project one stored row, restoring corrected effective event semantics."""
    canonical, identity_state, governance = _subject_projection(row, subjects)
    confidence = reporting._effective_confidence(str(row["confidence"]), state["status"], str(row["completeness"]), identity_state)
    event_type = str(row["event_type"])
    occurred_at = str(row["occurred_at"])
    correction_ref = row["correction_ref"]
    if not query.history and correction_ref is not None:
        event_type, occurred_at = _effective_event_semantics(reporting, row, query.now_epoch)
        correction_ref = None
    return {
        "schema_version": 1, "record_ref": str(row["record_ref"]), "event_ref": str(row["event_ref"]),
        "source": _source_record(row, state),
        "event": {"type": event_type, "occurred_at": occurred_at, "correction_of": correction_ref},
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
    rows = reporting._effective_rows(query)
    output: list[dict[str, Any]] = []
    for row in rows:
        key = (str(row["source"]), str(row["account_ref"]))
        state = source_state.get(key)
        if state is None:
            raise PerformanceContractError(
                "source state is unavailable at the requested boundary"
            )
        output.append(
            _event_record(
                reporting,
                row,
                state,
                subjects,
                query,
            )
        )
    return output
