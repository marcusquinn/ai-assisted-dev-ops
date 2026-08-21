#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Hermetic coverage for manual Google Trends CSV validation and persistence."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "domain-opportunity"
sys.path.insert(0, str(SCRIPTS))

from domain_opportunity_store import DomainOpportunityStore  # noqa: E402
from domain_opportunity_trends import inspect_export, load_manifest  # noqa: E402

HELPER = SCRIPTS / "domain-opportunity-trends.py"


class TrendsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.db = self.root / "trends.sqlite"
        self.manifest = FIXTURES / "google-trends-manifest.json"
        self.csv = FIXTURES / "google-trends-interest.csv"
        with DomainOpportunityStore(self.db, initialize=True) as store:
            with store.transaction():
                store.begin_source_run("fixture-listings", "fixture", started_at="2026-08-20T00:00:00Z")
                for identifier, fqdn, digest in (("listing-1", "example.com", "a" * 64), ("listing-2", "example-two.com", "b" * 64)):
                    store.upsert_listing_observation({"provider": "fixture", "provider_listing_id": identifier, "fqdn": fqdn, "sld": fqdn.split(".")[0], "tld": "com", "status": "active", "auction_type": "auction", "current_price_micros": 0, "current_price_currency": "USD", "bid_count": 0, "start_time": "2026-08-20T00:00:00Z", "end_time": "2026-08-22T00:00:00Z", "source_url": f"https://example.test/{identifier}", "observed_at": "2026-08-20T00:00:00Z", "source_run_id": "fixture-listings", "payload_hash": digest})
                store.complete_source_run("fixture-listings", 2)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def command(self, *arguments: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
        completed = subprocess.run([sys.executable, str(HELPER), *arguments], text=True, capture_output=True, check=False)  # nosec B603
        self.assertEqual(completed.returncode, expected, completed.stderr)
        return completed

    def test_inspect_import_and_exact_replay_are_hermetic(self) -> None:
        inspected = json.loads(self.command("inspect", "--manifest", str(self.manifest), "--input", str(self.csv)).stdout)
        self.assertEqual(inspected["series"], 2)
        _, parsed = inspect_export(load_manifest(self.manifest), self.csv)
        self.assertEqual(parsed[0].partial_points, ("2026-02-01T00:00:00Z",))
        first = json.loads(self.command("import", "--manifest", str(self.manifest), "--input", str(self.csv), "--db", str(self.db)).stdout)
        second = json.loads(self.command("import", "--manifest", str(self.manifest), "--input", str(self.csv), "--db", str(self.db)).stdout)
        self.assertEqual(first["raw_hash"], second["raw_hash"])
        with DomainOpportunityStore(self.db) as store:
            self.assertEqual(store.status()["counts"]["trend_series"], 2)
            self.assertEqual(store.status()["counts"]["trend_points"], 4)

    def test_term_order_mismatch_fails_before_mutation(self) -> None:
        bad = self.root / "bad.csv"
        bad.write_text("Month,example two,example\n2026-01,12,34\n", encoding="utf-8")
        self.command("import", "--manifest", str(self.manifest), "--input", str(bad), "--db", str(self.db), expected=2)
        with DomainOpportunityStore(self.db) as store:
            self.assertEqual(store.status()["counts"]["trend_series"], 0)

    def test_queue_is_bounded_and_includes_browser_handoff(self) -> None:
        queued = json.loads(self.command("queue", "--db", str(self.db), "--output", str(self.root / "queue")).stdout)
        self.assertEqual(len(queued["manifests"]), 1)
        self.assertIn("visible browser tab", queued["browser_checklist"][0])

    def test_timeframe_mismatch_fails_before_mutation(self) -> None:
        bad = self.root / "bad-timeframe.csv"
        bad.write_text("Month,example,example two\n2027-01,12,34\n", encoding="utf-8")
        self.command("import", "--manifest", str(self.manifest), "--input", str(bad), "--db", str(self.db), expected=2)
        with DomainOpportunityStore(self.db) as store:
            self.assertEqual(store.status()["counts"]["trend_series"], 0)


if __name__ == "__main__":
    unittest.main()
