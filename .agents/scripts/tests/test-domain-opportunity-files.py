#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hermetic coverage for bounded local auction-inventory ingestion."""

from __future__ import annotations

import gzip
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from domain_opportunity_files import DomainOpportunityFileError, ImportOptions, import_inventory, inspect  # noqa: E402
from domain_opportunity_store import DomainOpportunityStore  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "domain-opportunity"


class DomainOpportunityFileTests(unittest.TestCase):
    """Exercise provider mapping, archive fuses, rejects, and repeat import safety."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database = self.root / "inventory.sqlite"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_inspect_reports_headers_without_creating_database(self) -> None:
        result = inspect(FIXTURES / "godaddy-inventory.csv", "godaddy")
        self.assertEqual(result["missing_required_headers"], [])
        self.assertEqual(result["archive_format"], "plain")
        self.assertFalse(self.database.exists())

    def test_plain_gzip_and_zip_normalize_to_one_observation(self) -> None:
        plain = (FIXTURES / "snapnames-inventory.csv").read_bytes()
        compressed = self.root / "inventory.csv.gz"
        compressed.write_bytes(gzip.compress(plain))
        archive = self.root / "inventory.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
            output.writestr("inventory.csv", plain)
        options = ImportOptions(observed_at="2026-08-21T10:00:00Z")
        first = import_inventory(FIXTURES / "snapnames-inventory.csv", "snapnames", self.database, options)
        second = import_inventory(compressed, "snapnames", self.database, options)
        third = import_inventory(archive, "snapnames", self.database, options)
        self.assertEqual((first["imported"], second["imported"], third["imported"]), (1, 0, 0))
        with DomainOpportunityStore(self.database) as store:
            self.assertEqual(store.status()["counts"]["listing_observations"], 1)

    def test_bad_rows_are_isolated_and_rejects_are_atomic(self) -> None:
        source = self.root / "rows.csv"
        source.write_text(
            (FIXTURES / "godaddy-inventory.csv").read_text(encoding="utf-8")
            + "bad,gd-101,nope,0,2026-08-20T10:00:00Z,2026-08-22T10:00:00Z,active,https://auctions.example.test/gd-101\n",
            encoding="utf-8",
        )
        rejects = self.root / "rejects.jsonl"
        result = import_inventory(source, "godaddy", self.database, ImportOptions(rejects_path=str(rejects)))
        self.assertEqual((result["records"], result["rejected"]), (1, 1))
        self.assertEqual(json.loads(rejects.read_text(encoding="utf-8"))["line"], 3)

    def test_generic_normalized_jsonl_requires_explicit_profile(self) -> None:
        source = self.root / "normalized.jsonl"
        source.write_text(
            json.dumps(
                {
                    "fqdn": "authorized.example",
                    "status": "active",
                    "auction_type": "auction",
                    "current_price_micros": 1_000_000,
                    "current_price_currency": "USD",
                    "bid_count": 0,
                    "start_time": "2026-08-20T10:00:00Z",
                    "end_time": "2026-08-22T10:00:00Z",
                    "source_url": "https://export.example.test/one",
                    "observed_at": "2026-08-21T10:00:00Z",
                }
            )
            + "\n",
            encoding="utf-8",
        )
        result = import_inventory(source, "generic", self.database)
        self.assertEqual(result["imported"], 1)

    def test_unsafe_archives_and_missing_headers_fail_before_store_creation(self) -> None:
        archive = self.root / "unsafe.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("../escape.csv", "Domain\nexample.com\n")
        with self.assertRaisesRegex(DomainOpportunityFileError, "unsafe"):
            import_inventory(archive, "godaddy", self.database)
        missing = self.root / "missing.csv"
        missing.write_text("Domain Name,Current Bid\nexample.com,1\n", encoding="utf-8")
        with self.assertRaisesRegex(DomainOpportunityFileError, "missing required"):
            import_inventory(missing, "godaddy", self.database)
        self.assertFalse(self.database.exists())


if __name__ == "__main__":
    unittest.main()
