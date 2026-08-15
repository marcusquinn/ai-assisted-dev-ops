#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hermetic coverage for campaign growth planning, approval, and recovery."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / ".agents" / "scripts" / "campaign-growth-helper.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "campaign-growth"


class CampaignGrowthE2E(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary.name) / "repo"
        self.campaign = self.repo / "_campaigns" / "active" / "northstar"
        self.campaign.mkdir(parents=True)
        shutil.copy(FIXTURES / "intake.json", self.campaign / "intake.json")
        self.evidence = self.repo / "evidence.json"
        shutil.copy(FIXTURES / "evidence-happy.json", self.evidence)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_helper(self, *arguments: str, expected: int = 0) -> dict[str, object]:
        result = subprocess.run([sys.executable, str(HELPER), *arguments], capture_output=True, text=True, check=False)  # nosec B603
        self.assertEqual(result.returncode, expected, result.stderr)
        return json.loads(result.stdout) if result.stdout else {}

    def test_plan_is_non_mutating_and_describes_fallbacks(self) -> None:
        plan = self.run_helper("plan", "--intake", str(self.campaign / "intake.json"))
        self.assertTrue(plan["dry_run"])
        self.assertFalse(plan["mutation"])
        self.assertIn("distribution receipts", plan["artifacts"])
        self.assertFalse((self.campaign / "orchestration").exists())

    def test_happy_path_persists_idempotent_evidence_checkpoint(self) -> None:
        first = self.run_helper("start", "northstar", "--repo", str(self.repo), "--evidence", str(self.evidence))
        resumed = self.run_helper("resume", "northstar", "--repo", str(self.repo), "--evidence", str(self.evidence))
        self.assertEqual(first["status"], "succeeded")
        self.assertEqual(first["operation_ids"], ["op-reddit-001", "op-x-001"])
        self.assertEqual(first["generation"], resumed["generation"])

    def test_missing_approval_stops_distribution_without_false_success(self) -> None:
        evidence = json.loads(self.evidence.read_text(encoding="utf-8"))
        del evidence["stages"]["distribution"]["approval"]
        self.evidence.write_text(json.dumps(evidence), encoding="utf-8")
        state = self.run_helper("start", "northstar", "--repo", str(self.repo), "--evidence", str(self.evidence))
        self.assertEqual(state["status"], "review_required")
        self.assertEqual(state["stages"]["distribution"]["status"], "review_required")
        self.assertEqual(state["stages"]["performance"]["status"], "not_started")

    def test_unknown_provider_and_partial_metrics_remain_visible(self) -> None:
        evidence = json.loads(self.evidence.read_text(encoding="utf-8"))
        evidence["stages"]["distribution"]["status"] = "unknown"
        evidence["stages"]["performance"]["status"] = "partial"
        self.evidence.write_text(json.dumps(evidence), encoding="utf-8")
        state = self.run_helper("status", "northstar", "--repo", str(self.repo), "--evidence", str(self.evidence))
        self.assertEqual(state["status"], "unknown")
        self.assertEqual(state["stages"]["performance"]["status"], "not_started")

    def test_failure_and_recovery_inputs_stop_only_the_affected_route(self) -> None:
        cases = (
            ("missing evidence", "research", "blocked", "blocked"),
            ("unlicensed asset", "production", "blocked", "blocked"),
            ("unsupported provider", "distribution", "blocked", "blocked"),
            ("rate limit", "distribution", "partial", "partial"),
            ("suppression", "performance", "partial", "partial"),
            ("insufficient experiment evidence", "report", "blocked", "blocked"),
        )
        for reason, stage, status, overall in cases:
            with self.subTest(reason=reason):
                evidence = json.loads((FIXTURES / "evidence-happy.json").read_text(encoding="utf-8"))
                evidence["stages"][stage]["status"] = status
                evidence["stages"][stage]["reason"] = reason
                self.evidence.write_text(json.dumps(evidence), encoding="utf-8")
                state = self.run_helper("status", "northstar", "--repo", str(self.repo), "--evidence", str(self.evidence))
                self.assertEqual(state["status"], overall)
                self.assertEqual(state["stages"][stage]["status"], status)

    def test_claim_or_creative_approval_requires_review(self) -> None:
        intake = json.loads((self.campaign / "intake.json").read_text(encoding="utf-8"))
        intake["approvals"]["creative"] = "pending"
        (self.campaign / "intake.json").write_text(json.dumps(intake), encoding="utf-8")
        state = self.run_helper("status", "northstar", "--repo", str(self.repo), "--evidence", str(self.evidence))
        self.assertEqual(state["status"], "review_required")
        self.assertEqual(state["stages"]["review"]["status"], "review_required")


if __name__ == "__main__":
    unittest.main()
