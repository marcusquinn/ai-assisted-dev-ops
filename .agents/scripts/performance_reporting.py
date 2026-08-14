#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only projections, reconciliation, and bounded exports."""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import sqlite3
import time
from collections import defaultdict
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path
from typing import Any, Iterable

from performance_contract import (
    PerformanceContractError,
    canonical_json,
    decimal_json,
    decimal_wire,
    metric_definition,
    parse_timestamp,
    require_alias,
    timestamp_epoch,
    utc_now,
    wire_json,
)
from performance_store import MarketingPerformanceStore

SUBJECT_REF_RE = re.compile(r"^mkt-subj-v1:[a-f0-9]{64}$")
QUARANTINE_REF_RE = re.compile(r"^mkt-quarantine-v1:[a-f0-9]{64}$")
CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2, "verified": 3}


def read_snapshot(method: Any) -> Any:
    """Keep multi-query projections on one SQLite read snapshot."""

    @wraps(method)
    def wrapper(self: "PerformanceReporting", *args: Any, **kwargs: Any) -> Any:
        owns_snapshot = not self.connection.in_transaction
        if owns_snapshot:
            self.connection.execute("BEGIN")
        try:
            return method(self, *args, **kwargs)
        finally:
            if owns_snapshot:
                self.connection.rollback()

    return wrapper


class PerformanceReporting:
    """Build privacy-safe current views from immutable performance history."""

    def __init__(self, store: MarketingPerformanceStore) -> None:
        self.store = store
        self.connection = store.connection

    def _source_rows(self, now_epoch: int | None = None) -> list[dict[str, Any]]:
        now = int(time.time()) if now_epoch is None else now_epoch
        effective_resolutions = {
            str(row["target_ref"])
            for row in self.connection.execute(
                "SELECT target_ref,effective_at FROM reconciliations "
                "WHERE action='resolve_quarantine'"
            )
            if timestamp_epoch(str(row["effective_at"])) <= now
        }
        event_refs = {
            str(row["event_ref"])
            for row in self.connection.execute("SELECT DISTINCT event_ref FROM events")
        }
        unresolved: dict[tuple[str, str], int] = defaultdict(int)
        for row in self.connection.execute("SELECT * FROM quarantine"):
            if str(row["quarantine_ref"]) in effective_resolutions:
                continue
            if (
                str(row["reason"]) == "correction_target_pending"
                and str(row["source_event_ref"]) in event_refs
            ):
                continue
            unresolved[(str(row["source"]), str(row["account_ref"]))] += 1
        active_leases = {
            (str(row["source"]), str(row["account_ref"]))
            for row in self.connection.execute(
                "SELECT source,account_ref FROM leases WHERE expires_at>?",
                (now,),
            )
        }
        output: list[dict[str, Any]] = []
        for row in self.connection.execute(
            "SELECT * FROM sources ORDER BY source,account_ref"
        ):
            key = (str(row["source"]), str(row["account_ref"]))
            observed_at = row["last_observed_at"]
            lag_seconds = None
            stale = False
            if observed_at is not None:
                lag_seconds = int(max(0, now - timestamp_epoch(str(observed_at))))
                stale = lag_seconds > int(row["stale_after_seconds"])
            status = str(row["status"])
            if unresolved.get(key, 0) > 0:
                status = "partial"
            elif key in active_leases:
                status = "leased"
            elif stale:
                status = "stale"
            output.append(
                {
                    "source": key[0],
                    "account_ref": key[1],
                    "adapter": str(row["adapter"]),
                    "status": status,
                    "coverage": str(row["coverage"]),
                    "missing_scopes": json.loads(str(row["missing_scopes_json"])),
                    "cursor_present": row["cursor_ref"] is not None,
                    "last_observed_at": observed_at,
                    "last_success_at": row["last_success_at"],
                    "stale_after_seconds": int(row["stale_after_seconds"]),
                    "lag_seconds": lag_seconds,
                    "stale": stale,
                    "unresolved_quarantine": unresolved.get(key, 0),
                }
            )
        return output

    def _effective_rows(
        self,
        *,
        history: bool = False,
        source: str | None = None,
        account_ref: str | None = None,
        campaign_id: str | None = None,
    ) -> list[sqlite3.Row]:
        clauses: list[str] = []
        parameters: list[str] = []
        for field, value in (("source", source), ("account_ref", account_ref)):
            if value is not None:
                clauses.append(f"{field}=?")
                parameters.append(value)
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        rows = list(
            self.connection.execute(
                "SELECT * FROM events" + where + " ORDER BY occurred_at,recorded_at,record_ref",
                tuple(parameters),
            )
        )
        if history:
            return [row for row in rows if campaign_id is None or row["campaign_id"] == campaign_id]
        latest: dict[tuple[str, str, str], sqlite3.Row] = {}
        for row in rows:
            key = (str(row["source"]), str(row["account_ref"]), str(row["event_ref"]))
            previous = latest.get(key)
            if previous is None or int(row["revision"]) > int(previous["revision"]):
                latest[key] = row
        correction_refs = {
            str(row["correction_ref"])
            for row in latest.values()
            if row["correction_ref"] is not None
        }
        effective = [
            row
            for row in rows
            if latest.get((str(row["source"]), str(row["account_ref"]), str(row["event_ref"]))) is row
            and str(row["event_ref"]) not in correction_refs
        ]
        return [
            row for row in effective if campaign_id is None or row["campaign_id"] == campaign_id
        ]

    def _current_links(
        self, now_timestamp: str
    ) -> tuple[dict[str, str], dict[str, str], list[dict[str, Any]]]:
        latest: dict[str, sqlite3.Row] = {}
        latest_keys: dict[str, tuple[float, float, str]] = {}
        rows = list(self.connection.execute("SELECT * FROM identity_links"))
        history = [
            dict(row)
            for row in sorted(
                rows,
                key=lambda item: (
                    timestamp_epoch(str(item["effective_at"])),
                    timestamp_epoch(str(item["recorded_at"])),
                    str(item["link_ref"]),
                ),
            )
        ]
        for row in rows:
            member = str(row["member_subject_id"])
            ordering = (
                timestamp_epoch(str(row["effective_at"])),
                timestamp_epoch(str(row["recorded_at"])),
                str(row["link_ref"]),
            )
            if (
                ordering[0] <= timestamp_epoch(now_timestamp)
                and ordering > latest_keys.get(member, (float("-inf"), float("-inf"), ""))
            ):
                latest[member] = row
                latest_keys[member] = ordering
        links: dict[str, str] = {}
        states: dict[str, str] = {}
        for member, row in latest.items():
            action = str(row["action"])
            states[member] = "linked" if action == "link" else "split"
            if action == "link":
                links[member] = str(row["canonical_subject_id"])
        return links, states, history

    @staticmethod
    def _canonical(subject_id: str, links: dict[str, str]) -> tuple[str, bool]:
        current = subject_id
        seen = {current}
        for _ in range(32):
            target = links.get(current)
            if target is None:
                return current, False
            if target in seen:
                return subject_id, True
            seen.add(target)
            current = target
        return subject_id, True

    def _assert_identity_graph_acyclic_from(self, effective_at: str) -> None:
        effective_epoch = timestamp_epoch(effective_at)
        boundaries = [
            str(row["effective_at"])
            for row in self.connection.execute(
                "SELECT DISTINCT effective_at FROM identity_links"
            )
            if timestamp_epoch(str(row["effective_at"])) >= effective_epoch
        ]
        for boundary in sorted(boundaries, key=timestamp_epoch):
            links, _states, _history = self._current_links(boundary)
            if any(self._canonical(subject_id, links)[1] for subject_id in links):
                raise PerformanceContractError(
                    "identity reconciliation must not create a cyclic link graph"
                )

    @read_snapshot
    def subject_records(self, now_epoch: int | None = None) -> list[dict[str, Any]]:
        """Project subjects conservatively across explicit link/split history."""
        now_timestamp = (
            datetime.fromtimestamp(now_epoch, timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z")
            if now_epoch is not None
            else utc_now()
        )
        links, states, identity_history = self._current_links(now_timestamp)
        kinds: dict[str, str] = {}
        identity_states: dict[str, str] = {}
        subjects: set[str] = set()
        for row in self.connection.execute(
            "SELECT subject_id,subject_kind,identity_state FROM events WHERE subject_id IS NOT NULL"
        ):
            subject_id = str(row["subject_id"])
            subjects.add(subject_id)
            kinds.setdefault(subject_id, str(row["subject_kind"]))
            identity_states.setdefault(subject_id, str(row["identity_state"]))
        for row in identity_history:
            subjects.add(str(row["canonical_subject_id"]))
            subjects.add(str(row["member_subject_id"]))
        groups: dict[str, set[str]] = defaultdict(set)
        cycles: set[str] = set()
        for subject_id in subjects:
            canonical, cycle = self._canonical(subject_id, links)
            groups[canonical].add(subject_id)
            if cycle:
                cycles.add(canonical)
        consent_rows = sorted(
            [dict(row) for row in self.connection.execute("SELECT * FROM consent_ledger")],
            key=lambda row: (
                timestamp_epoch(str(row["effective_at"])),
                timestamp_epoch(str(row["observed_at"])),
                str(row["ledger_ref"]),
            ),
        )
        suppression_rows = sorted(
            [dict(row) for row in self.connection.execute("SELECT * FROM suppression_ledger")],
            key=lambda row: (
                timestamp_epoch(str(row["effective_at"])),
                timestamp_epoch(str(row["observed_at"])),
                str(row["ledger_ref"]),
            ),
        )
        output: list[dict[str, Any]] = []
        for canonical, members in sorted(groups.items()):
            member_consent = [row for row in consent_rows if str(row["subject_id"]) in members]
            member_suppression = [row for row in suppression_rows if str(row["subject_id"]) in members]
            latest_consent: dict[tuple[str, str], dict[str, Any]] = {}
            latest_consent_keys: dict[tuple[str, str], tuple[float, float, str]] = {}
            for row in member_consent:
                key = (str(row["subject_id"]), str(row["purpose"]))
                ordering = (
                    timestamp_epoch(str(row["effective_at"])),
                    timestamp_epoch(str(row["observed_at"])),
                    str(row["ledger_ref"]),
                )
                if (
                    ordering[0] <= timestamp_epoch(now_timestamp)
                    and ordering > latest_consent_keys.get(
                        key,
                        (float("-inf"), float("-inf"), ""),
                    )
                ):
                    latest_consent[key] = row
                    latest_consent_keys[key] = ordering
            latest_suppression: dict[str, dict[str, Any]] = {}
            latest_suppression_keys: dict[str, tuple[float, float, str]] = {}
            for row in member_suppression:
                key = str(row["subject_id"])
                ordering = (
                    timestamp_epoch(str(row["effective_at"])),
                    timestamp_epoch(str(row["observed_at"])),
                    str(row["ledger_ref"]),
                )
                if (
                    ordering[0] <= timestamp_epoch(now_timestamp)
                    and ordering > latest_suppression_keys.get(
                        key,
                        (float("-inf"), float("-inf"), ""),
                    )
                ):
                    latest_suppression[key] = row
                    latest_suppression_keys[key] = ordering
            audience_states = [
                str(latest_consent[(member, "audience")]["state"])
                if (member, "audience") in latest_consent
                else "unknown"
                for member in members
            ]
            suppressed = any(
                str(row["state"]) == "suppressed" for row in latest_suppression.values()
            )
            if canonical in cycles:
                eligible, reason = False, "identity_ambiguous"
            elif suppressed:
                eligible, reason = False, "suppressed"
            elif "denied" in audience_states:
                eligible, reason = False, "consent_denied"
            elif audience_states and all(state == "granted" for state in audience_states):
                eligible, reason = True, "eligible"
            else:
                eligible, reason = False, "consent_unknown"
            group_history = [
                row for row in identity_history if str(row["member_subject_id"]) in members
            ]
            state = "ambiguous" if canonical in cycles else "linked" if len(members) > 1 else states.get(canonical, identity_states.get(canonical, "isolated"))
            kind = kinds.get(canonical) or next((kinds[item] for item in sorted(members) if item in kinds), "anonymous")
            output.append(
                {
                    "schema_version": 1,
                    "subject_id": canonical,
                    "kind": kind,
                    "identity_state": state,
                    "canonical_subject_id": canonical,
                    "aliases": sorted(members),
                    "consent": [self._consent_record(row) for row in member_consent],
                    "suppression": [self._suppression_record(row) for row in member_suppression],
                    "identity_history": [self._identity_record(row) for row in group_history],
                    "audience_eligible": eligible,
                    "eligibility_reason": reason,
                }
            )
        return output

    @staticmethod
    def _provenance(row: dict[str, Any]) -> dict[str, Any]:
        return {
            "source": str(row["source"]),
            "account_ref": str(row["account_ref"]),
            "observed_at": str(row["observed_at"]),
            "evidence_ref": str(row["evidence_ref"]),
        }

    def _consent_record(self, row: dict[str, Any]) -> dict[str, Any]:
        return {
            "purpose": str(row["purpose"]),
            "state": str(row["state"]),
            "lawful_basis": row["lawful_basis"],
            "effective_at": str(row["effective_at"]),
            "provenance": self._provenance(row),
        }

    def _suppression_record(self, row: dict[str, Any]) -> dict[str, Any]:
        return {
            "state": str(row["state"]),
            "reason": row["reason"],
            "effective_at": str(row["effective_at"]),
            "provenance": self._provenance(row),
        }

    @staticmethod
    def _identity_record(row: dict[str, Any]) -> dict[str, Any]:
        return {
            "action": str(row["action"]),
            "canonical_subject_id": str(row["canonical_subject_id"]),
            "member_subject_id": str(row["member_subject_id"]),
            "effective_at": str(row["effective_at"]),
            "provenance": {
                "source": "owner",
                "account_ref": "owner-reconciliation",
                "observed_at": str(row["recorded_at"]),
                "evidence_ref": str(row["evidence_ref"]),
            },
        }

    @staticmethod
    def _effective_confidence(
        confidence: str,
        source_status: str,
        completeness: str,
        identity_state: str,
    ) -> str:
        cap = "verified"
        if completeness == "partial" or source_status == "partial":
            cap = "medium"
        elif completeness == "unknown" or source_status in {"unavailable", "unknown"}:
            cap = "low"
        elif source_status == "stale":
            cap = "high"
        if identity_state == "ambiguous" and CONFIDENCE_RANK[cap] > CONFIDENCE_RANK["high"]:
            cap = "high"
        return confidence if CONFIDENCE_RANK[confidence] <= CONFIDENCE_RANK[cap] else cap

    @read_snapshot
    def event_records(
        self,
        *,
        history: bool = False,
        source: str | None = None,
        account_ref: str | None = None,
        campaign_id: str | None = None,
        now_epoch: int | None = None,
    ) -> list[dict[str, Any]]:
        """Return schema-valid pseudonymous event records."""
        source_state = {
            (row["source"], row["account_ref"]): row
            for row in self._source_rows(now_epoch)
        }
        subjects = {row["subject_id"]: row for row in self.subject_records(now_epoch)}
        records: list[dict[str, Any]] = []
        for row in self._effective_rows(
            history=history,
            source=source,
            account_ref=account_ref,
            campaign_id=campaign_id,
        ):
            state = source_state[(str(row["source"]), str(row["account_ref"]))]
            subject_id = row["subject_id"]
            if subject_id is None:
                governance = {"audience_eligible": False, "eligibility_reason": "aggregate"}
                canonical_subject = None
                identity_state = str(row["identity_state"])
            else:
                subject = next(
                    (item for item in subjects.values() if str(subject_id) in item["aliases"]),
                    None,
                )
                canonical_subject = subject["subject_id"] if subject else str(subject_id)
                identity_state = subject["identity_state"] if subject else str(row["identity_state"])
                governance = {
                    "audience_eligible": bool(subject and subject["audience_eligible"]),
                    "eligibility_reason": subject["eligibility_reason"] if subject else "consent_unknown",
                }
            effective_confidence = self._effective_confidence(
                str(row["confidence"]),
                state["status"],
                str(row["completeness"]),
                identity_state,
            )
            records.append(
                {
                    "schema_version": 1,
                    "record_ref": str(row["record_ref"]),
                    "event_ref": str(row["event_ref"]),
                    "source": {
                        "kind": str(row["source"]),
                        "account_ref": str(row["account_ref"]),
                        "revision": int(row["revision"]),
                        "observed_at": str(row["observed_at"]),
                        "recorded_at": str(row["recorded_at"]),
                        "source_observed_at": (
                            str(row["source_observed_at"])
                            if row["source_observed_at"] is not None
                            else None
                        ),
                        "source_recorded_at": (
                            str(row["source_recorded_at"])
                            if row["source_recorded_at"] is not None
                            else None
                        ),
                        "evidence_ref": str(row["evidence_ref"]),
                        "coverage": state["coverage"],
                        "missing_scopes": state["missing_scopes"],
                    },
                    "event": {
                        "type": str(row["event_type"]),
                        "occurred_at": str(row["occurred_at"]),
                        "correction_of": row["correction_ref"],
                    },
                    "subject": {
                        "subject_id": canonical_subject,
                        "kind": str(row["subject_kind"]),
                        "identity_state": identity_state,
                    },
                    "scope": {
                        **{
                            field: row[field]
                            for field in (
                                "campaign_id",
                                "channel",
                                "creative_id",
                                "touchpoint_id",
                                "outcome_id",
                            )
                        },
                        "dimensions": json.loads(str(row["dimensions_json"])),
                    },
                    "measurement": {
                        "metric_id": str(row["metric_id"]),
                        "value": decimal_wire(str(row["value_text"])),
                        "unit": str(row["unit"]),
                        "aggregation": str(row["aggregation"]),
                        "currency": row["currency"],
                        "period_start": row["period_start"],
                        "period_end": row["period_end"],
                    },
                    "quality": {
                        "confidence": str(row["confidence"]),
                        "effective_confidence": effective_confidence,
                        "completeness": str(row["completeness"]),
                        "source_type": str(row["source_type"]),
                        "collected_by": str(row["collected_by"]),
                        "evidence_ref": str(row["evidence_ref"]),
                    },
                    "governance": governance,
                }
            )
        return records

    @staticmethod
    def phase1_result(event: dict[str, Any]) -> dict[str, Any]:
        """Project one normalized event to the backwards-compatible result shape."""
        scope = event["scope"]
        subject = event["subject"]
        if scope["campaign_id"]:
            result_subject = {"type": "campaign", "id": scope["campaign_id"]}
        elif subject["subject_id"]:
            result_subject = {"type": "marketing_subject", "id": subject["subject_id"]}
        else:
            result_subject = {"type": "marketing", "id": "aggregate"}
        dimensions = dict(scope["dimensions"])
        dimensions.update(
            {
                key: value
                for key, value in {
                    "channel": scope["channel"],
                    "creative_id": scope["creative_id"],
                    "touchpoint_id": scope["touchpoint_id"],
                    "outcome_id": scope["outcome_id"],
                    "currency": event["measurement"]["currency"],
                }.items()
                if value is not None
            }
        )
        return {
            "schema_version": 1,
            "metric": metric_definition(event["measurement"]["metric_id"], event["measurement"]["unit"]),
            "subject": result_subject,
            "dimensions": dimensions,
            "measurement": {
                "value": (
                    decimal_json(event["measurement"]["value"])
                    if isinstance(event["measurement"]["value"], str)
                    else event["measurement"]["value"]
                ),
                "unit": event["measurement"]["unit"],
                "aggregation": event["measurement"]["aggregation"],
                "period_start": event["measurement"]["period_start"],
                "period_end": event["measurement"]["period_end"],
                "observed_at": (
                    event["source"]["source_observed_at"]
                    or event["source"]["observed_at"]
                ),
                "recorded_at": (
                    event["source"]["source_recorded_at"]
                    or event["source"]["recorded_at"]
                ),
                "source_event_at": event["event"]["occurred_at"],
            },
            "quality": {
                "confidence": event["quality"]["effective_confidence"],
                "source_type": event["quality"]["source_type"],
                "source_ref": event["quality"]["evidence_ref"],
                "collected_by": event["quality"]["collected_by"],
                "evidence": [event["record_ref"]],
                "notes": None,
            },
        }

    @read_snapshot
    def status(self, now_epoch: int | None = None) -> dict[str, Any]:
        """Return conservative source freshness and recovery state."""
        sources = self._source_rows(now_epoch)
        event_history = int(self.connection.execute("SELECT COUNT(*) FROM events").fetchone()[0])
        effective = len(self._effective_rows())
        quarantine_total = int(self.connection.execute("SELECT COUNT(*) FROM quarantine").fetchone()[0])
        unresolved = sum(source["unresolved_quarantine"] for source in sources)
        status = "ready"
        if not sources:
            status = "uninitialized"
        elif any(source["status"] in {"partial", "stale", "leased"} for source in sources):
            status = "partial"
        return {
            "schema": "aidevops.marketing-performance-status/v1",
            "status": status,
            "sources": sources,
            "summary": {
                "source_accounts": len(sources),
                "event_history": event_history,
                "effective_events": effective,
                "subjects": len(self.subject_records(now_epoch)),
                "quarantine_total": quarantine_total,
                "unresolved_quarantine": unresolved,
            },
        }

    def reconcile(self, document: Any) -> dict[str, Any]:
        """Append explicit owner identity or quarantine decisions."""
        if not isinstance(document, dict) or document.get("schema") != "aidevops.marketing-performance-reconciliation/v1":
            raise PerformanceContractError("unsupported reconciliation schema")
        actions = document.get("actions")
        if not isinstance(actions, list) or not actions:
            raise PerformanceContractError("reconciliation actions must be a non-empty array")
        recorded_at = utc_now()
        applied = 0
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            for action in actions:
                if not isinstance(action, dict):
                    raise PerformanceContractError("reconciliation action must be an object")
                action_type = action.get("action")
                required_fields = {
                    "link": {
                        "action",
                        "canonical_subject_id",
                        "member_subject_id",
                        "effective_at",
                        "evidence_ref",
                    },
                    "split": {
                        "action",
                        "canonical_subject_id",
                        "member_subject_id",
                        "effective_at",
                        "evidence_ref",
                    },
                    "resolve_quarantine": {
                        "action",
                        "quarantine_ref",
                        "resolution",
                        "effective_at",
                        "evidence_ref",
                    },
                }
                expected = required_fields.get(str(action_type))
                if expected is None:
                    raise PerformanceContractError("reconciliation action is unsupported")
                if set(action) != expected:
                    raise PerformanceContractError(
                        "reconciliation action fields do not match the action contract"
                    )
                effective_at = parse_timestamp(action.get("effective_at"), "reconciliation.effective_at")
                evidence = require_alias(
                    action.get("evidence_ref"),
                    "reconciliation.evidence_ref",
                )
                evidence_ref = "mkt-evidence-v1:sha256:" + hashlib.sha256(evidence.encode("utf-8")).hexdigest()
                if action_type in {"link", "split"}:
                    canonical = action.get("canonical_subject_id")
                    member = action.get("member_subject_id")
                    if not isinstance(canonical, str) or not SUBJECT_REF_RE.fullmatch(canonical):
                        raise PerformanceContractError("canonical_subject_id is invalid")
                    if not isinstance(member, str) or not SUBJECT_REF_RE.fullmatch(member):
                        raise PerformanceContractError("member_subject_id is invalid")
                    if canonical == member:
                        raise PerformanceContractError("identity reconciliation requires distinct subjects")
                    known = int(self.connection.execute(
                        "SELECT COUNT(DISTINCT subject_id) FROM events WHERE subject_id IN (?,?)",
                        (canonical, member),
                    ).fetchone()[0])
                    if known < 2:
                        raise PerformanceContractError("identity reconciliation subjects must already exist")
                    competing = list(
                        self.connection.execute(
                            "SELECT action,canonical_subject_id FROM identity_links "
                            "WHERE member_subject_id=? AND effective_at=?",
                            (member, effective_at),
                        )
                    )
                    if any(
                        str(row["action"]) != action_type
                        or str(row["canonical_subject_id"]) != canonical
                        for row in competing
                    ):
                        raise PerformanceContractError(
                            "identity reconciliation conflicts at the same effective time"
                        )
                    link_ref = self.store.pseudonym("mkt-link-v1", action_type, canonical, member, effective_at, evidence_ref)
                    self.connection.execute(
                        "INSERT OR IGNORE INTO identity_links(link_ref,action,canonical_subject_id,member_subject_id,evidence_ref,effective_at,recorded_at) VALUES(?,?,?,?,?,?,?)",
                        (link_ref, action_type, canonical, member, evidence_ref, effective_at, recorded_at),
                    )
                    if action_type == "link":
                        self._assert_identity_graph_acyclic_from(effective_at)
                    target_ref = member
                    resolution = action_type
                    reconciliation_parts = [
                        str(action_type),
                        str(canonical),
                        str(member),
                    ]
                elif action_type == "resolve_quarantine":
                    target_ref = action.get("quarantine_ref")
                    resolution = action.get("resolution")
                    if not isinstance(target_ref, str) or not QUARANTINE_REF_RE.fullmatch(target_ref):
                        raise PerformanceContractError("quarantine_ref is invalid")
                    if resolution not in {"discarded", "superseded"}:
                        raise PerformanceContractError("quarantine resolution is unsupported")
                    if self.connection.execute("SELECT 1 FROM quarantine WHERE quarantine_ref=?", (target_ref,)).fetchone() is None:
                        raise PerformanceContractError("quarantine target does not exist")
                    reconciliation_parts = [
                        str(action_type),
                        str(target_ref),
                        str(resolution),
                    ]
                reconciliation_ref = self.store.pseudonym(
                    "mkt-reconciliation-v1",
                    *reconciliation_parts,
                    effective_at,
                    evidence_ref,
                )
                payload = {
                    key: value
                    for key, value in action.items()
                    if key not in {"evidence_ref"}
                }
                cursor = self.connection.execute(
                    "INSERT OR IGNORE INTO reconciliations(reconciliation_ref,action,target_ref,resolution,evidence_ref,effective_at,recorded_at,payload_json) VALUES(?,?,?,?,?,?,?,?)",
                    (reconciliation_ref, action_type, target_ref, resolution, evidence_ref, effective_at, recorded_at, canonical_json(payload)),
                )
                applied += int(cursor.rowcount > 0)
            self.connection.commit()
        except Exception:
            self.connection.rollback()
            raise
        return {"schema": "aidevops.marketing-performance-reconciliation-result/v1", "applied": applied}

    @staticmethod
    def _atomic_jsonl(path: Path, records: Iterable[dict[str, Any]]) -> int:
        if path.is_symlink() or path.parent.is_symlink() or (
            path.exists() and not path.is_file()
        ):
            raise PerformanceContractError("export destination must be a regular file")
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
        count = 0
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                for record in records:
                    handle.write(wire_json(record) + "\n")
                    count += 1
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
        finally:
            if temporary.exists():
                temporary.unlink()
        return count

    def export(self, purpose: str, output: Path, *, result_format: bool = False) -> dict[str, Any]:
        """Write an explicit pseudonymous measurement or eligible-audience export."""
        if purpose == "audience":
            records = [record for record in self.subject_records() if record["audience_eligible"]]
        elif purpose == "measurement":
            events = self.event_records()
            records = [self.phase1_result(event) for event in events] if result_format else events
        else:
            raise PerformanceContractError("export purpose is unsupported")
        count = self._atomic_jsonl(output, records)
        return {
            "schema": "aidevops.marketing-performance-export/v1",
            "purpose": purpose,
            "records": count,
            "output": str(output),
            "identifier_policy": "pseudonymous-subjects-validated-dimensions",
        }

    def write_campaign_summary(self, campaign_id: str, account_ref: str) -> Path:
        """Write only aggregate campaign result projections to a versionable summary."""
        campaign_id = require_alias(campaign_id, "campaign id")
        account_ref = require_alias(account_ref, "account ref")
        if self.store.paths.summaries.is_symlink() or not self.store.paths.summaries.is_dir():
            raise PerformanceContractError("campaign summary directory is unsafe")
        account_directory = self.store.paths.summaries / account_ref
        if account_directory.is_symlink() or (
            account_directory.exists() and not account_directory.is_dir()
        ):
            raise PerformanceContractError("campaign account summary directory is unsafe")
        account_directory.mkdir(mode=0o755, exist_ok=True)
        events = self.event_records(
            source="campaign",
            account_ref=account_ref,
            campaign_id=campaign_id,
        )
        records = [
            self.phase1_result(event)
            for event in events
            if event["subject"]["subject_id"] is None
        ]
        destination = account_directory / f"{campaign_id}.jsonl"
        self._atomic_jsonl(destination, records)
        os.chmod(destination, 0o644)
        return destination

    @read_snapshot
    def rebuild_summaries(self) -> dict[str, Any]:
        """Rebuild aggregate campaign summaries from immutable event history."""
        campaign_accounts = [
            (str(row["campaign_id"]), str(row["account_ref"]))
            for row in self.connection.execute(
                "SELECT DISTINCT campaign_id,account_ref FROM events "
                "WHERE source='campaign' AND campaign_id IS NOT NULL "
                "ORDER BY campaign_id,account_ref"
            )
        ]
        paths = [
            str(self.write_campaign_summary(campaign_id, account_ref))
            for campaign_id, account_ref in campaign_accounts
        ]
        return {
            "schema": "aidevops.marketing-performance-rebuild/v1",
            "campaigns": len(campaign_accounts),
            "summaries": paths,
            "history_rewritten": False,
        }
