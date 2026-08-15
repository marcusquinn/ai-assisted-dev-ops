#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hermetic attribution, experiment, privacy, and recommendation contracts."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
AGENTS = SCRIPTS.parent
HELPER = SCRIPTS / "marketing-optimization-helper.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "marketing-optimization"

sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("marketing_optimization_helper", HELPER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load marketing optimization helper")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MarketingOptimizationTests(unittest.TestCase):
    """Use only synthetic aggregate and pseudonymous evidence."""

    @staticmethod
    def fixture(name: str) -> dict[str, object]:
        return json.loads((FIXTURES / name).read_text(encoding="utf-8"))

    def attribution(self, **overrides: object) -> dict[str, object]:
        arguments = {
            "document": self.fixture("journeys.json"),
            "model": "last_touch",
            "window_days": 30,
            "model_version": 1,
            "window_version": 1,
            "run_id": "fixture-run",
            "generated_at": "2026-08-01T00:00:00Z",
        }
        arguments.update(overrides)
        return MODULE.attribute(**arguments)

    def test_last_touch_is_deterministic_and_adjusts_refunds_and_costs(self) -> None:
        first = self.attribution()
        second = self.attribution(run_id="different-run")
        self.assertEqual(first["projection_id"], second["projection_id"])
        reversed_events = self.fixture("journeys.json")
        reversed_events["events"].reverse()
        replay = self.attribution(document=reversed_events)
        self.assertEqual(first["projection_id"], replay["projection_id"])
        self.assertEqual(1, first["coverage"]["matched_outcomes"])
        self.assertEqual(1, first["coverage"]["identity_uncertain_outcomes"])
        search = next(row for row in first["aggregates"] if row["campaign_id"] == "conversion")
        self.assertEqual("120", search["revenue"])
        self.assertEqual("20", search["refunds"])
        self.assertEqual("30", search["costs"])
        self.assertEqual("100", search["net_revenue"])
        self.assertEqual("observational", first["causality"]["claim"])

    def test_window_and_model_version_produce_auditable_new_projection(self) -> None:
        original = self.attribution()
        changed = self.attribution(model_version=2)
        expired = self.attribution(window_days=5)
        self.assertNotEqual(original["projection_id"], changed["projection_id"])
        self.assertEqual(1, expired["coverage"]["matched_outcomes"])
        self.assertGreater(expired["coverage"]["unattributed_outcomes"], 0)
        checkout = next(row for row in expired["aggregates"] if row["campaign_id"] == "checkout")
        self.assertEqual("120", checkout["revenue"])

    def test_no_data_and_direct_model_are_explicit(self) -> None:
        empty = {"source_snapshot": "fixture:empty", "coverage": "unknown", "events": []}
        projection = self.attribution(document=empty, model="direct")
        self.assertEqual([], projection["aggregates"])
        self.assertEqual("unknown", projection["coverage"]["source"])
        direct = self.attribution(model="direct")
        self.assertEqual(1, direct["coverage"]["matched_outcomes"])
        self.assertEqual(1, direct["coverage"]["identity_uncertain_outcomes"])

    def test_experiment_candidate_winner_requires_preregistered_thresholds(self) -> None:
        result = MODULE.analyze_experiment(
            self.fixture("experiment.json"),
            "analysis-run",
            "2026-07-16T00:00:00Z",
        )
        self.assertEqual("candidate_winner", result["status"])
        self.assertEqual("treatment", result["winner"])
        self.assertFalse(result["peeking_detected"])
        self.assertEqual("experimental", result["causality"])

    def test_sparse_and_peeked_experiments_are_insufficient(self) -> None:
        sparse = MODULE.analyze_experiment(
            self.fixture("sparse-experiment.json"),
            "analysis-run",
            "2026-07-16T00:00:00Z",
        )
        self.assertEqual("insufficient_evidence", sparse["status"])
        peeked_input = self.fixture("experiment.json")
        peeked = MODULE.analyze_experiment(peeked_input, "peek-run", "2026-07-02T00:00:00Z")
        self.assertEqual("insufficient_evidence", peeked["status"])
        self.assertTrue(peeked["peeking_detected"])

    def test_guardrail_regression_blocks_winner(self) -> None:
        experiment = self.fixture("experiment.json")
        experiment["observations"][1]["guardrails"]["marketing.unsubscribe.total"]["regressed"] = True
        result = MODULE.analyze_experiment(experiment, "guardrail-run", "2026-07-16T00:00:00Z")
        self.assertEqual("guardrail_regression", result["status"])
        self.assertIsNone(result["winner"])

    def test_novelty_seasonality_and_contradictions_prevent_a_winner(self) -> None:
        validity_input = self.fixture("experiment.json")
        validity_input["validity_flags"] = ["novelty", "seasonality"]
        validity = MODULE.analyze_experiment(validity_input, "validity-run", "2026-07-16T00:00:00Z")
        self.assertEqual("insufficient_evidence", validity["status"])
        contradictory_input = self.fixture("experiment.json")
        contradictory_input["contradictory_metrics"] = True
        contradictory = MODULE.analyze_experiment(contradictory_input, "contradictory-run", "2026-07-16T00:00:00Z")
        self.assertEqual("contradictory", contradictory["status"])

    def test_report_suppresses_sparse_cohorts_and_marks_stale_sources(self) -> None:
        projection = self.attribution()
        report = MODULE.build_report(
            {
                "attribution": projection,
                "experiments": [],
                "sources": [{"source": "crm", "coverage": "partial", "observed_at": "2026-07-01T00:00:00Z"}],
                "metrics": [
                    {"metric_id": "marketing.impressions.total", "value": 10000, "unit": "impression", "cohort_size": 10000, "source_ref": "fixture:analytics"},
                    {"metric_id": "marketing.leads.qualified", "value": 3, "unit": "lead", "cohort_size": 3, "source_ref": "fixture:crm"},
                ],
                "contradictions": ["Platform conversions exceed verified CRM conversions."],
            },
            minimum_cohort=10,
            stale_after_hours=48,
            generated_at="2026-08-01T00:00:00Z",
        )
        self.assertEqual("stale", report["status"])
        self.assertEqual([], report["funnel"])
        self.assertGreater(report["privacy"]["suppressed_aggregates"], 0)
        self.assertFalse(report["privacy"]["individual_records"])
        self.assertEqual("marketing.impressions.total", report["metrics"]["reach"][0]["metric_id"])
        self.assertEqual([], report["metrics"]["leads_and_stages"])
        self.assertTrue(report["contradictions"])

    def test_recommendation_is_idempotent_approval_bound_and_superseding(self) -> None:
        evidence = {
            "refs": ["mkt-experiment-analysis-v1:fixture"],
            "source_snapshot": "fixture:experiment-2026-08-01",
            "sample_size": 2000,
            "causality": "experimental",
            "target_metric": "marketing.conversions.total",
            "observed_problem": "Control conversion is lower than the tested treatment.",
            "expected_impact": {"minimum": 0.03, "maximum": 0.08, "unit": "relative_fraction"},
            "confidence": "high",
        }
        document = {"evidence": evidence, "minimum_sample": 250, "supersedes": []}
        first = MODULE.recommend(document, "content", "campaign owner approval", "Restore the control creative.", "2026-09-01T00:00:00Z", "2026-08-01T00:00:00Z")
        replay = MODULE.recommend(document, "content", "campaign owner approval", "Restore the control creative.", "2026-09-01T00:00:00Z", "2026-08-02T00:00:00Z")
        self.assertEqual(first["recommendation_id"], replay["recommendation_id"])
        self.assertEqual("awaiting_approval", first["status"])
        self.assertIn("spend", first["prohibited_mutations"])
        successor = MODULE.recommend({**document, "supersedes": [first["recommendation_id"]]}, "content", "campaign owner approval", "Restore the control creative.", "2026-09-01T00:00:00Z", "2026-08-03T00:00:00Z")
        self.assertEqual([first["recommendation_id"]], successor["supersedes"])
        self.assertNotEqual(first["recommendation_id"], successor["recommendation_id"])

    def test_atomic_output_preserves_complete_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "published" / "report.json"
            MODULE._write(self.attribution(), str(output))
            self.assertEqual("aidevops.marketing-attribution/v1", json.loads(output.read_text(encoding="utf-8"))["schema"])
            older_different = self.attribution(model_version=2, generated_at="2026-07-31T00:00:00Z")
            with self.assertRaises(MODULE.OptimizationError):
                MODULE._write(older_different, str(output))

    def test_contract_schemas_are_valid_json(self) -> None:
        for name in (
            "marketing-attribution.schema.json",
            "marketing-experiment.schema.json",
            "growth-recommendation.schema.json",
        ):
            schema = json.loads((AGENTS / "schemas" / name).read_text(encoding="utf-8"))
            self.assertEqual("https://json-schema.org/draft/2020-12/schema", schema["$schema"])


if __name__ == "__main__":
    unittest.main()
