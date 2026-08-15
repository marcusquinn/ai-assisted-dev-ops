#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Compatibility facade for read-only marketing performance projections."""

from __future__ import annotations

import os
import secrets
import time
from functools import wraps
from pathlib import Path
from typing import Any, Iterable

from _performance_reporting_events import EventQuery, event_records as _event_records
from _performance_reporting_queries import (
    assert_identity_graph_acyclic as _assert_identity_graph_acyclic,
    current_links as _current_links,
    effective_rows as _effective_rows,
    source_rows as _source_rows,
)
from _performance_reporting_reconciliation import (
    QUARANTINE_REF_RE as _QUARANTINE_REF_RE,
    SUBJECT_REF_RE as _SUBJECT_REF_RE,
    reconcile as _reconcile,
)
from _performance_reporting_subjects import subject_records as _subject_records
from performance_contract import (
    PerformanceContractError,
    decimal_json,
    metric_definition,
    require_alias,
    timestamp_epoch,
    wire_json,
)
from performance_store import MarketingPerformanceStore

CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2, "verified": 3}
QUARANTINE_REF_RE = _QUARANTINE_REF_RE
SUBJECT_REF_RE = _SUBJECT_REF_RE


def _source_confidence_cap(source_status: str, completeness: str) -> str:
    if completeness == "partial" or source_status == "partial":
        return "medium"
    if completeness == "unknown" or source_status in {"unavailable", "unknown"}:
        return "low"
    if source_status == "stale":
        return "high"
    return "verified"


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

    def _source_rows(self, now_epoch: float | None = None) -> list[dict[str, Any]]:
        return _source_rows(self, now_epoch)

    def _effective_rows(
        self,
        query: EventQuery | None = None,
        **options: Any,
    ) -> list[Any]:
        if query is not None and options:
            raise TypeError("event query cannot be combined with legacy options")
        return _effective_rows(self, query or EventQuery.from_options(options))

    def _current_links(
        self,
        now_timestamp: str,
        *,
        recorded_through: str | None = None,
    ) -> tuple[dict[str, str], dict[str, str], list[dict[str, Any]]]:
        return _current_links(self, now_timestamp, recorded_through=recorded_through)

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
        _assert_identity_graph_acyclic(self, effective_at)

    @read_snapshot
    def subject_records(self, now_epoch: float | None = None) -> list[dict[str, Any]]:
        """Project subjects conservatively across explicit link/split history."""
        return _subject_records(self, now_epoch)

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
        cap = _source_confidence_cap(source_status, completeness)
        identity_cap = "high" if identity_state in {"ambiguous", "split"} else "verified"
        return min((confidence, cap, identity_cap), key=CONFIDENCE_RANK.__getitem__)

    @read_snapshot
    def event_records(self, **options: Any) -> list[dict[str, Any]]:
        """Return schema-valid pseudonymous event records."""
        return _event_records(self, EventQuery.from_options(options))

    @staticmethod
    def phase1_result(event: dict[str, Any]) -> dict[str, Any]:
        """Project one normalized event to the backwards-compatible result shape."""
        scope = event["scope"]
        subject = event["subject"]
        if scope["campaign_id"]:
            result_subject = {"type": "campaign", "id": scope["campaign_id"]}
        elif subject["subject_id"]:
            result_subject = {
                "type": "marketing_subject",
                "id": subject["subject_id"],
            }
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
        measurement_value = event["measurement"]["value"]
        return {
            "schema_version": 1,
            "metric": metric_definition(
                event["measurement"]["metric_id"],
                event["measurement"]["unit"],
            ),
            "subject": result_subject,
            "dimensions": dimensions,
            "measurement": {
                "value": (
                    decimal_json(measurement_value)
                    if isinstance(measurement_value, str)
                    else measurement_value
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
    def status(self, now_epoch: float | None = None) -> dict[str, Any]:
        """Return conservative source freshness and recovery state."""
        boundary_epoch = time.time() if now_epoch is None else now_epoch
        sources = self._source_rows(boundary_epoch)
        event_history = len(
            self._effective_rows(history=True, now_epoch=boundary_epoch)
        )
        effective = len(self._effective_rows(now_epoch=boundary_epoch))
        quarantine_total = sum(
            1
            for row in self.connection.execute("SELECT recorded_at FROM quarantine")
            if timestamp_epoch(str(row["recorded_at"])) <= boundary_epoch
        )
        unresolved = sum(source["unresolved_quarantine"] for source in sources)
        status = "ready"
        if not sources:
            status = "uninitialized"
        elif any(
            source["status"] in {"partial", "stale", "leased"}
            for source in sources
        ):
            status = "partial"
        return {
            "schema": "aidevops.marketing-performance-status/v1",
            "status": status,
            "sources": sources,
            "summary": {
                "source_accounts": len(sources),
                "event_history": event_history,
                "effective_events": effective,
                "subjects": len(self.subject_records(boundary_epoch)),
                "quarantine_total": quarantine_total,
                "unresolved_quarantine": unresolved,
            },
        }

    def reconcile(self, document: Any) -> dict[str, Any]:
        """Append explicit owner identity or quarantine decisions."""
        return _reconcile(self, document)

    @staticmethod
    def _atomic_jsonl(path: Path, records: Iterable[dict[str, Any]]) -> int:
        unsafe_existing = path.exists() and not path.is_file()
        if path.is_symlink() or path.parent.is_symlink() or unsafe_existing:
            raise PerformanceContractError("export destination must be a regular file")
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(
            f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp"
        )
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

    def export(
        self,
        purpose: str,
        output: Path,
        *,
        result_format: bool = False,
    ) -> dict[str, Any]:
        """Write an explicit pseudonymous measurement or audience export."""
        if purpose == "audience":
            records = [
                record
                for record in self.subject_records()
                if record["audience_eligible"]
            ]
        elif purpose == "measurement":
            events = self.event_records()
            records = (
                [self.phase1_result(event) for event in events]
                if result_format
                else events
            )
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
        """Write aggregate campaign results to a versionable summary."""
        campaign_id = require_alias(campaign_id, "campaign id")
        account_ref = require_alias(account_ref, "account ref")
        if self.store.paths.summaries.is_symlink() or not self.store.paths.summaries.is_dir():
            raise PerformanceContractError("campaign summary directory is unsafe")
        account_directory = self.store.paths.summaries / account_ref
        unsafe_account_directory = account_directory.exists() and not account_directory.is_dir()
        if account_directory.is_symlink() or unsafe_account_directory:
            raise PerformanceContractError(
                "campaign account summary directory is unsafe"
            )
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
