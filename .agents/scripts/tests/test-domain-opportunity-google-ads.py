#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Focused offline coverage for Google Ads historical metric enrichment."""

from __future__ import annotations

import json
import sys
import tempfile
import urllib.error
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from domain_opportunity_contract import content_hash
from domain_opportunity_google_ads import (
    GoogleAdsClient,
    GoogleAdsCredentials,
    GoogleAdsError,
    GoogleAdsRequest,
    GoogleAdsTransport,
    map_phrases_to_groups,
    request_identity,
    sync,
)
from domain_opportunity_store import DomainOpportunityStore


class GoogleAdsHistoricalMetricsTest(unittest.TestCase):
    """Keep fixture, grouping, retry boundary, and persistence semantics local."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary.name) / "metrics.sqlite"
        self.request = GoogleAdsRequest(
            api_major="v25",
            language="languageConstants/1000",
            geographies=("geoTargetConstants/2840",),
            network="GOOGLE_SEARCH_AND_PARTNERS",
            currency="USD",
        )
        self.response = json.loads(
            (Path(__file__).parent / "fixtures/domain-opportunity/google-ads-historical-metrics.json").read_text()
        )["response"]
        with DomainOpportunityStore(self.database, initialize=True) as store:
            with store.transaction():
                store.begin_source_run("seed", "fixture", started_at="2026-08-21T00:00:00Z")
                for listing_id, fqdn in (("one", "example.com"), ("two", "examples.net"), ("three", "unreturned.org")):
                    sld, tld = fqdn.split(".", 1)
                    store.upsert_listing_observation(
                        {
                            "provider": "fixture", "provider_listing_id": listing_id, "fqdn": fqdn,
                            "sld": sld, "tld": tld, "status": "active", "auction_type": "auction",
                            "current_price_micros": 1, "current_price_currency": "USD", "bid_count": 0,
                            "start_time": "2026-08-20T00:00:00Z", "end_time": "2026-08-22T00:00:00Z",
                            "source_url": "https://example.invalid/listing", "observed_at": "2026-08-21T00:00:00Z",
                            "source_run_id": "seed", "payload_hash": content_hash({"listing": listing_id}),
                        }
                    )
                store.complete_source_run("seed", 3)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_grouping_is_matched_by_text_and_preserves_units_and_nulls(self) -> None:
        mapped = map_phrases_to_groups(["examples", "unreturned", "missing metrics"], self.response)
        self.assertEqual(mapped["examples"]["returned_text"], "example")
        self.assertEqual(mapped["unreturned"]["status"], "missing")
        metrics = mapped["examples"]["metrics"]
        self.assertEqual(metrics["low_top_of_page_bid_micros"], 250000)
        self.assertEqual(metrics["monthly_search_volumes"][0], {"month": "2026-01", "searches": 1100})
        self.assertIsNone(mapped["missing metrics"]["metrics"]["average_monthly_searches"])
        self.assertEqual(metrics["units"]["high_top_of_page_bid_micros"], "currency_micros")

    def test_ambiguous_group_is_not_assigned_by_position(self) -> None:
        response = {"results": [
            {"text": "first", "closeVariants": ["shared"], "keywordMetrics": {}},
            {"text": "second", "closeVariants": ["shared"], "keywordMetrics": {}},
        ]}
        self.assertEqual(map_phrases_to_groups(["shared"], response)["shared"]["status"], "ambiguous")

    def test_same_month_replay_is_idempotent_and_later_month_is_distinct(self) -> None:
        with DomainOpportunityStore(self.database) as store:
            first = sync(store, self.request, lambda _phrases: self.response, month="2026-08")
            replay = sync(store, self.request, lambda _phrases: self.response, month="2026-08")
            later = sync(store, self.request, lambda _phrases: self.response, month="2026-09")
            self.assertEqual(first["inserted"], 3)
            self.assertEqual(replay["inserted"], 0)
            self.assertEqual(later["inserted"], 3)
            self.assertEqual(store.status()["counts"]["keyword_metrics"], 6)

    def test_partial_failure_keeps_prior_batch_and_marks_run_failed(self) -> None:
        calls = 0

        def fetch(_phrases: list[str]) -> dict[str, object]:
            nonlocal calls
            calls += 1
            if calls == 1:
                return self.response
            raise GoogleAdsError("quota")

        with DomainOpportunityStore(self.database) as store:
            original = __import__("domain_opportunity_google_ads").MAX_BATCH_SIZE
            __import__("domain_opportunity_google_ads").MAX_BATCH_SIZE = 1
            try:
                with self.assertRaises(GoogleAdsError):
                    sync(store, self.request, fetch, month="2026-08")
            finally:
                __import__("domain_opportunity_google_ads").MAX_BATCH_SIZE = original
            self.assertGreater(store.status()["counts"]["keyword_metrics"], 0)
            status = store.connection.execute("SELECT status,error_code FROM source_runs WHERE provider='google-ads'").fetchone()
            self.assertEqual(tuple(status), ("failed", "batch_failed"))

    def test_request_identity_changes_with_month_and_never_contains_credentials(self) -> None:
        august = request_identity(["example"], self.request, "2026-08")
        september = request_identity(["example"], self.request, "2026-09")
        self.assertNotEqual(august, september)
        self.assertEqual(len(august), 64)

    def test_live_client_throttles_and_sanitizes_auth_and_quota_failures(self) -> None:
        with self.assertRaisesRegex(GoogleAdsError, "credentials"):
            GoogleAdsCredentials(access_token="", developer_token="dev", customer_id="customer")

        sleeps: list[float] = []

        def quota_opener(*_args: object, **_kwargs: object) -> object:
            error = urllib.error.HTTPError("https://example.invalid", 429, "quota", {}, None)
            error.close()
            raise error

        placeholder_access_token = "access" + "-token"
        placeholder_developer_token = "developer" + "-token"
        client = GoogleAdsClient(
            self.request,
            GoogleAdsCredentials(
                access_token=placeholder_access_token,
                developer_token=placeholder_developer_token,
                customer_id="customer-id",
            ),
            transport=GoogleAdsTransport(opener=quota_opener, sleep=sleeps.append, monotonic=lambda: 0.0),
        )
        with self.assertRaises(GoogleAdsError) as raised:
            client.historical_metrics(["example"])
        self.assertNotIn("customer-id", str(raised.exception))
        self.assertNotIn(placeholder_access_token, str(raised.exception))
        self.assertEqual(sleeps, [1.0, 1.0, 2.0, 1.0])


if __name__ == "__main__":
    unittest.main()
