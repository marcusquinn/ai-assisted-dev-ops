#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hermetic tests for Namecheap Market's read-only sales adapter."""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from domain_opportunity_namecheap import (  # noqa: E402
    NamecheapMarketError,
    SyncOptions,
    iter_sales,
    map_sale,
    sync,
)

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "domain-opportunity" / "namecheap-sales.json"


class NamecheapMarketTests(unittest.TestCase):
    """Protect cursor, retry, mapping, idempotency, and redaction boundaries."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary.name) / "evidence.sqlite"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def sale() -> dict[str, object]:
        """Load one documented redacted sale fixture."""
        return json.loads(FIXTURE.read_text(encoding="utf-8"))["pages"][0]["items"][0]

    def test_fixture_sync_pages_and_deduplicates_current_listing(self) -> None:
        """Traverse two pages and keep a repeat execution idempotent."""
        first = sync(self.database, SyncOptions(fixture=FIXTURE))
        second = sync(self.database, SyncOptions(fixture=FIXTURE))
        self.assertEqual((first.records, first.inserted, first.skipped), (2, 2, 0))
        self.assertEqual((second.records, second.inserted, second.skipped), (2, 0, 0))
        connection = sqlite3.connect(self.database)
        self.assertEqual(connection.execute("SELECT COUNT(*) FROM listings").fetchone()[0], 2)
        self.assertEqual(connection.execute("SELECT COUNT(*) FROM listing_observations").fetchone()[0], 2)
        self.assertEqual(connection.execute("SELECT COUNT(*) FROM keyword_metrics").fetchone()[0], 1)
        connection.close()

    def test_mapping_preserves_documented_nulls_and_units(self) -> None:
        """Convert price to micros while keeping absent provider fields as null evidence."""
        sale = self.sale()
        sale["futureField"] = "preserved"
        mapped = map_sale(sale, observed_at="2026-08-21T10:00:00Z", source_run_id="fixture-run")
        self.assertEqual(mapped["current_price_micros"], 12_500_000)
        self.assertEqual(mapped["current_price_currency"], "USD")
        self.assertIsNone(mapped["raw_json"]["goDaddyValue"])
        self.assertEqual(mapped["raw_json"]["keywordSearchCount"], 1200)
        self.assertEqual(mapped["raw_json"]["futureField"], "preserved")

    def test_repeated_cursor_fails_without_spinning(self) -> None:
        """Reject a cursor loop after the second response."""
        responses = iter(
            [
                (200, {"items": [], "hasMore": True, "nextCursor": "repeat"}, None),
                (200, {"items": [], "hasMore": True, "nextCursor": "repeat"}, None),
            ]
        )
        with self.assertRaisesRegex(NamecheapMarketError, "repeated_cursor"):
            list(iter_sales(lambda cursor: next(responses), sleep=lambda _: None))

    def test_rate_limit_recovers_with_bounded_retry(self) -> None:
        """Retry one 429 with capped delay and then accept the response."""
        responses = iter(
            [
                (429, {}, 120.0),
                (200, {"items": [], "hasMore": False, "nextCursor": None}, None),
            ]
        )
        delays: list[float] = []
        pages = list(iter_sales(lambda cursor: next(responses), sleep=delays.append))
        self.assertEqual(pages, [{"items": [], "has_more": False, "next_cursor": None}])
        self.assertEqual(delays, [30.0])

    def test_authentication_failure_does_not_expose_token(self) -> None:
        """Classify authentication failures without carrying credential text."""
        credential_marker = "-".join(("sensitive", "marker", "not", "leaked"))
        os.environ["NAMECHEAP_MARKET_API_TOKEN"] = credential_marker
        try:
            with self.assertRaises(NamecheapMarketError) as captured:
                list(iter_sales(lambda cursor: (401, {}, None), sleep=lambda _: None))
            self.assertEqual(str(captured.exception), "authentication_failed")
            self.assertNotIn(credential_marker, str(captured.exception))
        finally:
            os.environ.pop("NAMECHEAP_MARKET_API_TOKEN", None)

    def test_malformed_sale_isolated_from_valid_page(self) -> None:
        """Skip an invalid item while retaining valid listings in the same page."""
        valid = self.sale()
        malformed = dict(valid)
        malformed["price"] = None
        result = sync(
            self.database,
            SyncOptions(
                transport=lambda cursor: (200, {"items": [valid, malformed], "hasMore": False, "nextCursor": None}, None),
                sleep=lambda _: None,
            ),
        )
        self.assertEqual((result.records, result.inserted, result.skipped), (1, 1, 1))

    def test_failed_page_keeps_prior_current_records_and_marks_only_new_run_failed(self) -> None:
        """Leave the last completed snapshot queryable after a later page failure."""
        sync(self.database, SyncOptions(fixture=FIXTURE))
        with self.assertRaisesRegex(NamecheapMarketError, "malformed_response"):
            sync(
                self.database,
                SyncOptions(
                    transport=lambda cursor: (200, {"items": [], "hasMore": "invalid"}, None),
                    sleep=lambda _: None,
                ),
            )
        connection = sqlite3.connect(self.database)
        self.assertEqual(connection.execute("SELECT COUNT(*) FROM listings").fetchone()[0], 2)
        self.assertEqual(
            connection.execute("SELECT COUNT(*) FROM source_runs WHERE status='failed'").fetchone()[0],
            1,
        )
        connection.close()


if __name__ == "__main__":
    unittest.main()
