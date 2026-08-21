#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Focused offline contracts for exact-match domain scoring."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from domain_opportunity_scoring import ScoringPolicy, exact_phrase_readings  # noqa: E402

CLI = SCRIPTS / "domain-opportunity-score.py"
FIXTURE = Path(__file__).parent / "fixtures/domain-opportunity/scoring-candidates.jsonl"


class DomainOpportunityScoringTest(unittest.TestCase):
    """Prove exact evidence, boundaries, unknowns, risk flags, and reruns."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary.name) / "scores.sqlite"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def command(self, *arguments: str) -> dict[str, object]:
        """Run the production CLI and decode one JSON result."""
        completed = subprocess.run(
            [sys.executable, str(CLI), *arguments], text=True, capture_output=True, check=False
        )  # nosec B603 -- fixed local helper
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout)

    def test_fixture_scores_exact_readings_and_rejects_malformed_rows(self) -> None:
        """Score valid candidates while retaining explicit invalid boundaries."""
        result = self.command("score", "--fixture", str(FIXTURE), "--db", str(self.database))
        self.assertEqual(result["imported"], 6)
        self.assertEqual(result["rejected"], 2)
        candidates = {item["domain"]: item for item in result["candidates"]}
        self.assertTrue(candidates["archeryclasses.com"]["eligible"])
        self.assertEqual(candidates["archeryclasses.com"]["phrase_readings"][0]["phrase"], "archery classes")
        self.assertFalse(candidates["best4you.com"]["eligible"])
        self.assertIn("non_ascii_or_punctuation", candidates["best4you.com"]["flags"])
        self.assertFalse(candidates["archery-classes.com"]["eligible"])
        self.assertIn("trademark_review", candidates["acmeoffers.com"]["risk_flags"])

    def test_unknown_evidence_is_not_a_measured_zero_and_rerun_is_idempotent(self) -> None:
        """Keep absent metrics unknown and avoid duplicate score rows/components."""
        first = self.command("score", "--fixture", str(FIXTURE), "--db", str(self.database))
        second = self.command("score", "--fixture", str(FIXTURE), "--db", str(self.database))
        self.assertEqual(first["run_id"], second["run_id"])
        first_archery = next(item for item in first["candidates"] if item["domain"] == "archeryclasses.com")
        second_archery = next(item for item in second["candidates"] if item["domain"] == "archeryclasses.com")
        self.assertEqual(first_archery["score_micros"], second_archery["score_micros"])
        explanation = self.command(
            "explain", "--db", str(self.database), "--domain", "archeryclasses.com", "--json"
        )
        self.assertEqual(explanation["components"]["demand"]["weight_micros"], 0)
        self.assertEqual(explanation["components"]["demand"]["evidence"]["status"], "unknown")
        readings = explanation["components"]["phrase_confidence"]["evidence"]["readings"]
        self.assertEqual(readings[0]["source"], "provider-search-query")
        self.assertEqual(readings[0]["confidence_micros"], 950_000)

        import sqlite3
        connection = sqlite3.connect(self.database)
        self.assertEqual(connection.execute("SELECT COUNT(*) FROM candidate_scores").fetchone()[0], 6)
        self.assertEqual(
            connection.execute("SELECT COUNT(*) FROM score_components").fetchone()[0],
            6 * len(first_archery["components"]),
        )
        connection.close()

    def test_ambiguous_exact_alternatives_are_preserved_and_policy_validates(self) -> None:
        """Never silently choose one exact reading or accept malformed bounds."""
        readings = exact_phrase_readings(
            "greenmarket",
            [
                {"phrase": "green market", "source": "provider", "confidence": 0.8},
                {"phrase": "greenmark et", "source": "operator", "confidence": 0.4},
                {"phrase": "green markets", "source": "invalid", "confidence": 1.0},
            ],
        )
        self.assertEqual([item["phrase"] for item in readings], ["green market", "greenmark et"])
        with self.assertRaisesRegex(ValueError, "length bounds"):
            ScoringPolicy(min_length=20, max_length=5).validate()


if __name__ == "__main__":
    unittest.main()
