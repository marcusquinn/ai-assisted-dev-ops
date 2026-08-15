#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Synthetic aggregate-fixture helpers for marketing optimization tests."""

from __future__ import annotations

import hashlib
import json
from typing import Any

from marketing_optimization_contract import MINIMUM_AGGREGATE_CELL_SIZE


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
