#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""End-to-end contracts for deterministic local opportunity reports."""

from __future__ import annotations

import csv
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from domain_opportunity_contract import CandidateScore, KeywordMetric, TrendSeries  # noqa: E402
from domain_opportunity_reporting import ReportOptions, build_report, render  # noqa: E402
from domain_opportunity_store import DomainOpportunityStore  # noqa: E402

HELPER = SCRIPTS / "domain-opportunity-helper.py"
AS_OF = "2026-08-21T12:00:00Z"


class ReportingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database = self.root / "evidence.sqlite"
        self._build_store()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def listing(identity: str, domain: str, price: int) -> dict[str, object]:
        return {
            "provider": "fixture", "provider_listing_id": identity, "fqdn": domain,
            "sld": domain.removesuffix(".com"), "tld": "com", "status": "active",
            "auction_type": "auction", "current_price_micros": price,
            "current_price_currency": "USD", "bid_count": 1,
            "start_time": "2026-08-20T00:00:00Z", "end_time": "2026-08-23T00:00:00Z",
            "source_url": f"https://example.invalid/{identity}", "observed_at": "2026-08-21T00:00:00Z",
            "source_run_id": "fixture-inventory", "payload_hash": identity * 64,
            "raw_json": {"phrase_evidence": []},
        }

    def _build_store(self) -> None:
        with DomainOpportunityStore(self.database, initialize=True) as store:
            with store.transaction():
                store.begin_source_run("fixture-inventory", "fixture", started_at="2026-08-21T00:00:00Z")
                store.upsert_listing_observation(self.listing("a", "alpha.com", 2_000_000))
                store.upsert_listing_observation(self.listing("b", "beta.com", 1_000_000))
                store.complete_source_run("fixture-inventory", 2)
                store.begin_source_run("fixture-score", "domain-opportunity-scoring", started_at="2026-08-21T01:00:00Z")
                store.insert_candidate_score(CandidateScore(
                    provider="fixture", provider_listing_id="b", source_run_id="fixture-score",
                    model="exact-match-com-v1", score_micros=800_000, observed_at="2026-08-21T01:00:00Z",
                    components={
                        "demand": {"value_micros": 700_000, "weight_micros": 100_000,
                                   "evidence": {"status": "measured", "source": "google-ads"}},
                        "structural_readability": {"value_micros": 900_000, "weight_micros": 200_000,
                                                   "evidence": {"status": "measured", "eligible": True,
                                                                "hard_filter_flags": []}},
                        "risk_quality": {"value_micros": 1_000_000, "weight_micros": 150_000,
                                         "evidence": {"status": "measured", "flags": []}},
                    },
                ))
                ads = {
                    "status": "found", "metrics": {"average_monthly_searches": 700},
                    "metric_source": "google_ads.keyword_plan_idea.generate_historical_metrics",
                    "language": "languageConstants/1000", "geographies": ["geoTargetConstants/2840"],
                    "network": "GOOGLE_SEARCH_AND_PARTNERS", "account_currency": "USD",
                    "retrieval_month": "2026-08", "input_phrase": "beta",
                }
                store.insert_keyword_metric(KeywordMetric(
                    provider="fixture", provider_listing_id="b", source_run_id="fixture-score",
                    source="google-ads", metric_name="historical_keyword_metrics", value=json.dumps(ads),
                    unit="json", observed_at="2026-08-21T02:00:00Z", payload_hash="c" * 64,
                ))
                store.insert_trend_series(TrendSeries(
                    provider="fixture", provider_listing_id="b", source_run_id="fixture-score",
                    source="google-trends-manual-export", query="beta", geography="US",
                    timeframe="2026-01-01 2026-02-28", observed_at="2026-08-21T03:00:00Z",
                    points=(("2026-01-01T00:00:00Z", 20), ("2026-02-01T00:00:00Z", 30)),
                ))
                store.complete_source_run("fixture-score", 3)

    def test_deterministic_ranked_projections_preserve_unknowns(self) -> None:
        original_socket = socket.socket
        socket.socket = lambda *_args, **_kwargs: self.fail("network access attempted")  # type: ignore[assignment]
        try:
            with DomainOpportunityStore(self.database) as store:
                first = build_report(store, ReportOptions(as_of=AS_OF))
            with DomainOpportunityStore(self.database) as store:
                second = build_report(store, ReportOptions(as_of=AS_OF))
        finally:
            socket.socket = original_socket
        self.assertEqual(first, second)
        self.assertEqual([item["domain"] for item in first["candidates"]], ["beta.com", "alpha.com"])
        self.assertIsNone(first["candidates"][1]["score_micros"])
        self.assertIn("score", first["candidates"][1]["missing_flags"])
        self.assertEqual(first["candidates"][0]["trends"]["direction"], "up")
        self.assertEqual(first["candidates"][0]["google_ads"]["metrics"]["average_monthly_searches"], 700)
        self.assertEqual(first["candidates"][0]["score_components"]["demand"]["unit"], "micros")
        self.assertEqual(first["candidates"][0]["score_freshness"], "fresh")
        json_output = render(first, "json")
        markdown_output = render(first, "markdown")
        csv_rows = list(csv.DictReader(io.StringIO(render(first, "csv"))))
        self.assertEqual(json.loads(json_output)["candidates"][0]["domain"], "beta.com")
        self.assertIn('"average_monthly_searches":700', markdown_output)
        self.assertEqual(csv_rows[1]["score_micros"], "")

    def test_cli_atomically_exports_all_formats(self) -> None:
        environment = os.environ.copy()
        guard = self.root / "guard"
        guard.mkdir()
        (guard / "sitecustomize.py").write_text(
            "import socket\ndef denied(*args, **kwargs): raise AssertionError('network access attempted')\nsocket.socket=denied\n",
            encoding="utf-8",
        )
        environment["PYTHONPATH"] = str(guard)
        for output_format in ("csv", "json", "markdown"):
            output = self.root / f"report.{output_format}"
            completed = subprocess.run(  # nosec B603 -- fixed local helper and fixture paths
                [sys.executable, str(HELPER), "report", "--db", str(self.database), "--format", output_format,
                 "--output", str(output), "--as-of", AS_OF],
                text=True, capture_output=True, check=False, env=environment,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(output.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
