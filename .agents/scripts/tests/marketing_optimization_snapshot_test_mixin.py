#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Snapshot and attribution cases shared by the optimization contract suite."""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from unittest import mock

from marketing_attribution import build_attribution
from marketing_optimization_contract import MINIMUM_AGGREGATE_CELL_SIZE
from marketing_optimization_io import snapshot_from_document, snapshot_from_repo
from marketing_optimization_test_support import (
    ACCOUNT,
    AS_OF,
    CAMPAIGN,
    aggregate_analysis_document,
    analysis_document,
    attribution_request,
)
from performance_adapters import AdapterResult
from performance_reporting import PerformanceReporting
from performance_store import MarketingPerformanceStore

SCRIPTS = Path(__file__).resolve().parents[1]
ATTRIBUTION_SCHEMA = SCRIPTS.parent / "schemas" / "marketing-attribution.schema.json"


def _raw_event(source_event_id: str, **fields: object) -> dict[str, object]:
    """Build one normalized currency event from explicit synthetic fields."""
    return {
        "source_event_id": source_event_id,
        "revision": 1,
        "event_type": fields["event_type"],
        "occurred_at": fields["occurred_at"],
        "correction_of": fields.get("correction_of"),
        "subject": {
            "kind": "lead",
            "identity_state": "isolated",
            "source_ref": fields["subject_ref"],
            "candidate_refs": [],
        },
        "scope": {
            "campaign_id": CAMPAIGN,
            "channel": "search",
            "outcome_id": fields["outcome_id"],
        },
        "measurement": {
            "metric_id": fields["metric_id"],
            "value": fields["value"],
            "unit": "currency",
            "aggregation": "sum",
            "currency": "USD",
        },
        "quality": {
            "confidence": "high",
            "completeness": "complete",
            "source_type": "fixture",
            "collected_by": "synthetic-fixture",
        },
        "governance": {"consent": [], "suppression": None},
    }


def _governed_event(
    source_event_id: str,
    subject_ref: str,
    **options: object,
) -> dict[str, object]:
    """Build one consent-bearing event with optional later suppression."""
    revision = int(options.get("revision", 1))
    governance: dict[str, object] = {
        "consent": [
            {
                "purpose": "audience",
                "state": "granted",
                "lawful_basis": "synthetic-test",
                "effective_at": "2026-08-11T00:00:00Z",
            }
        ],
        "suppression": None,
    }
    if options.get("suppressed") is True:
        governance["suppression"] = {
            "state": "suppressed",
            "reason": "synthetic-test",
            "effective_at": "2026-08-11T00:00:00Z",
        }
    return {
        "source_event_id": source_event_id,
        "revision": revision,
        "event_type": "conversion",
        "occurred_at": "2026-08-11T00:00:00Z",
        "correction_of": None,
        "subject": {
            "kind": "lead",
            "identity_state": "isolated",
            "source_ref": subject_ref,
            "candidate_refs": [],
        },
        "scope": {"campaign_id": CAMPAIGN, "channel": "search"},
        "measurement": {
            "metric_id": "marketing.conversions.total",
            "value": revision,
            "unit": "conversion",
            "aggregation": "sum",
            "currency": None,
        },
        "quality": {
            "confidence": "high",
            "completeness": "complete",
            "source_type": "fixture",
            "collected_by": "synthetic-fixture",
        },
        "governance": governance,
    }


def _adapter_result(
    events: list[dict[str, object]],
    cursor: str,
    observed_at: str,
    **options: object,
) -> AdapterResult:
    """Wrap synthetic events in one normalized adapter result."""
    batch = {
        "source": "normalized",
        "account_ref": ACCOUNT,
        "cursor": cursor,
        "observed_at": observed_at,
        "coverage": "complete",
        "missing_scopes": [],
        "events": events,
    }
    return AdapterResult(
        batch=batch,
        errors=options.get("errors") or [],
        raw_bytes=json.dumps(batch, sort_keys=True).encode("utf-8"),
        suffix=".json",
    )


class SnapshotAttributionMixin:
    """Behavioral cases mixed into the hermetic optimization TestCase."""

    repo: Path

    def test_live_snapshot_ignores_all_state_recorded_after_as_of(self) -> None:
        initial_epoch = int(datetime.fromisoformat("2026-08-11T01:00:00+00:00").timestamp())
        future_epoch = int(datetime.fromisoformat("2026-08-12T01:00:00+00:00").timestamp())
        with MarketingPerformanceStore.open(self.repo, provision=True) as store:
            with mock.patch("_performance_store_leases.time.time", return_value=initial_epoch):
                with mock.patch("_performance_store_ingest.time.time", return_value=initial_epoch):
                    with mock.patch(
                        "_performance_store_ingest.utc_now",
                        return_value="2026-08-11T01:00:00Z",
                    ):
                        store.ingest(
                            "normalized",
                            _adapter_result(
                                [
                                    _governed_event("event-a", "subject-a"),
                                    _governed_event("event-b", "subject-b"),
                                ],
                                "initial-cursor",
                                "2026-08-11T00:30:00Z",
                                errors=[
                                    {
                                        "index": "synthetic",
                                        "reason": "synthetic quarantine",
                                        "source_event_id": "quarantined-event",
                                    }
                                ],
                            ),
                        )
            subjects = [
                str(row["subject_id"])
                for row in store.connection.execute(
                    "SELECT DISTINCT subject_id FROM events ORDER BY subject_id"
                )
            ]
            quarantine_ref = str(
                store.connection.execute(
                    "SELECT quarantine_ref FROM quarantine"
                ).fetchone()[0]
            )

        boundary = "2026-08-11T12:00:00Z"
        before = snapshot_from_repo(
            self.repo,
            as_of=boundary,
            account_ref=ACCOUNT,
            campaign_id=CAMPAIGN,
        )

        with MarketingPerformanceStore.open(self.repo) as store:
            with mock.patch("_performance_store_leases.time.time", return_value=future_epoch):
                with mock.patch("_performance_store_ingest.time.time", return_value=future_epoch):
                    with mock.patch(
                        "_performance_store_ingest.utc_now",
                        return_value="2026-08-12T01:00:00Z",
                    ):
                        store.ingest(
                            "normalized",
                            _adapter_result(
                                [
                                    _governed_event(
                                        "event-a",
                                        "subject-a",
                                        revision=2,
                                        suppressed=True,
                                    )
                                ],
                                "future-cursor",
                                "2026-08-11T00:45:00Z",
                            ),
                        )
            with mock.patch(
                "_performance_reporting_reconciliation.utc_now",
                return_value="2026-08-12T01:00:00Z",
            ):
                with mock.patch(
                    "_performance_reporting_queries.utc_now",
                    return_value="2026-08-12T01:00:00Z",
                ):
                    PerformanceReporting(store).reconcile(
                        {
                            "schema": "aidevops.marketing-performance-reconciliation/v1",
                            "actions": [
                                {
                                    "action": "link",
                                    "canonical_subject_id": subjects[0],
                                    "member_subject_id": subjects[1],
                                    "effective_at": "2026-08-11T00:00:00Z",
                                    "evidence_ref": "synthetic-owner-link",
                                },
                                {
                                    "action": "resolve_quarantine",
                                    "quarantine_ref": quarantine_ref,
                                    "resolution": "discarded",
                                    "effective_at": "2026-08-11T00:00:00Z",
                                    "evidence_ref": "synthetic-owner-resolution",
                                },
                            ],
                        }
                    )

        after = snapshot_from_repo(
            self.repo,
            as_of=boundary,
            account_ref=ACCOUNT,
            campaign_id=CAMPAIGN,
        )

        self.assertEqual(before, after)
        self.assertEqual(2, len(after.events))
        self.assertEqual(2, len(after.subjects))
        self.assertEqual("partial", after.sources[0]["status"])
        self.assertEqual(1, after.sources[0]["unresolved_quarantine"])

    def test_live_snapshot_preserves_corrected_outcome_refund_chronology(self) -> None:
        events: list[dict[str, object]] = []
        for index in range(MINIMUM_AGGREGATE_CELL_SIZE):
            target_ref = f"revenue-{index}"
            subject_ref = f"subject-{index}"
            outcome_id = f"order-{index}"
            events.extend(
                (
                    _raw_event(
                        target_ref,
                        event_type="revenue",
                        occurred_at="2026-08-01T12:00:00Z",
                        subject_ref=subject_ref,
                        outcome_id=outcome_id,
                        metric_id="marketing.revenue.gross",
                        value=100,
                    ),
                    _raw_event(
                        f"correction-{index}",
                        event_type="correction",
                        occurred_at="2026-08-03T12:00:00Z",
                        subject_ref=subject_ref,
                        outcome_id=outcome_id,
                        metric_id="marketing.revenue.gross",
                        value=120,
                        correction_of=target_ref,
                    ),
                    _raw_event(
                        f"refund-{index}",
                        event_type="refund",
                        occurred_at="2026-08-02T12:00:00Z",
                        subject_ref=subject_ref,
                        outcome_id=outcome_id,
                        metric_id="marketing.revenue.refunded",
                        value=25,
                    ),
                )
            )
        batch = {
            "source": "normalized",
            "account_ref": ACCOUNT,
            "cursor": "corrected-refund-cursor",
            "observed_at": "2026-08-04T00:00:00Z",
            "coverage": "complete",
            "missing_scopes": [],
            "events": events,
        }
        result = AdapterResult(
            batch=batch,
            errors=[],
            raw_bytes=json.dumps(batch, sort_keys=True).encode("utf-8"),
            suffix=".json",
        )
        recorded_epoch = int(datetime.fromisoformat("2026-08-04T01:00:00+00:00").timestamp())
        with MarketingPerformanceStore.open(self.repo, provision=True) as store:
            with mock.patch("_performance_store_leases.time.time", return_value=recorded_epoch):
                with mock.patch("_performance_store_ingest.time.time", return_value=recorded_epoch):
                    with mock.patch(
                        "_performance_store_ingest.utc_now",
                        return_value="2026-08-04T01:00:00Z",
                    ):
                        store.ingest("normalized", result)

        snapshot = snapshot_from_repo(
            self.repo,
            as_of=AS_OF,
            account_ref=ACCOUNT,
            campaign_id=CAMPAIGN,
        )
        projection = build_attribution(
            snapshot,
            attribution_request(
                outcome_metric_id="marketing.revenue.gross",
                account_ref=ACCOUNT,
                campaign_id=CAMPAIGN,
            ),
        )

        self.assertEqual(120 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["gross_value"])
        self.assertEqual(25 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["refund_value"])
        self.assertEqual(95 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["net_value"])
        self.assertEqual(0, projection["coverage"]["unmatched_refunds"])

    def test_last_touch_attribution_is_deterministic_and_schema_valid(self) -> None:
        snapshot = snapshot_from_document(aggregate_analysis_document())
        first = build_attribution(snapshot, attribution_request())
        second = build_attribution(snapshot, attribution_request())

        self.assertEqual(first, second)
        self.assertEqual(MINIMUM_AGGREGATE_CELL_SIZE, first["outcomes"]["attributed_count"])
        self.assertTrue(all(item["suppressed"] for item in first["allocations"]))
        self.assertTrue(all(item["touchpoint_ref"] is None for item in first["allocations"]))
        self.assertEqual("complete", first["run"]["status"])
        self.assertEqual("observational_only", first["causal_assessment"]["status"])
        self.assert_schema(ATTRIBUTION_SCHEMA, first)

    def test_small_attribution_cells_hide_counts_values_and_dimensions(self) -> None:
        snapshot = snapshot_from_document(analysis_document())
        projection = build_attribution(snapshot, attribution_request(minimum_cell_size=10))

        self.assertTrue(projection["outcomes"]["suppressed"])
        self.assertIsNone(projection["outcomes"]["eligible_count"])
        self.assertIsNone(projection["allocations"][0]["channel"])
        self.assertIsNone(projection["allocations"][0]["value"])
        self.assertIsNone(projection["coverage"]["suppressed_allocations"])
        self.assertIsNone(projection["coverage"]["late_events"])
        self.assertIsNone(projection["coverage"]["unmatched_refunds"])
        self.assertEqual("low", projection["uncertainty"]["data_confidence"])
        self.assert_schema(ATTRIBUTION_SCHEMA, projection)
