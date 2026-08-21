#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hermetic contracts for the local domain-opportunity evidence foundation."""

from __future__ import annotations

import csv
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from domain_opportunity_contract import (  # noqa: E402
    CSV_COLUMNS,
    CandidateScore,
    KeywordMetric,
    TrendSeries,
)
from domain_opportunity_store import (  # noqa: E402
    DomainOpportunityStore,
    DomainOpportunityStoreError,
)

HELPER = SCRIPTS / "domain-opportunity-helper.py"


class DomainOpportunityTests(unittest.TestCase):
    """Exercise migrations, idempotency, provenance, and CSV interchange."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database = self.root / "evidence.sqlite"
        self.input = self.root / "records.jsonl"
        self.output = self.root / "records.csv"
        self.network_guard = self.root / "network-guard"
        self.network_guard.mkdir()
        (self.network_guard / "sitecustomize.py").write_text(
            "import socket\n"
            "def denied(*args, **kwargs):\n"
            "    raise AssertionError('network access attempted')\n"
            "socket.socket = denied\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def command(self, *arguments: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
        """Run the production CLI without network access."""
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(self.network_guard)
        completed = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(HELPER), *arguments],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )
        self.assertEqual(completed.returncode, expected, completed.stderr)
        return completed

    @staticmethod
    def record(*, price: int = 1_500_000, payload: str = "a" * 64) -> dict[str, object]:
        """Build one normalized provider fixture."""
        return {
            "provider": "fixture",
            "provider_listing_id": "listing-1",
            "fqdn": "example.com",
            "sld": "example",
            "tld": "com",
            "status": "active",
            "auction_type": "auction",
            "current_price_micros": price,
            "current_price_currency": "USD",
            "bid_count": 2,
            "start_time": "2026-08-20T10:00:00Z",
            "end_time": "2026-08-22T10:00:00Z",
            "source_url": "https://example.test/listing-1",
            "observed_at": "2026-08-21T10:00:00Z",
            "source_run_id": "fixture-run-1",
            "payload_hash": payload,
            "raw_json": {"fixture": True},
        }

    def write_records(self, *records: dict[str, object]) -> None:
        """Write normalized fixtures as JSONL."""
        self.input.write_text("".join(f"{json.dumps(record)}\n" for record in records), encoding="utf-8")

    def test_cli_init_reopen_import_idempotency_and_csv_round_trip(self) -> None:
        """Persist one fixture, retry it, preserve a change, and export stable CSV."""
        self.command("init", "--db", str(self.database))
        status = json.loads(self.command("status", "--db", str(self.database), "--json").stdout)
        self.assertEqual(status["schema_version"], 1)
        self.assertEqual(status["counts"]["listings"], 0)

        self.write_records(self.record())
        first = json.loads(
            self.command(
                "import-jsonl", "--db", str(self.database), "--input", str(self.input), "--provider", "fixture"
            ).stdout
        )
        second = json.loads(
            self.command(
                "import-jsonl", "--db", str(self.database), "--input", str(self.input), "--provider", "fixture"
            ).stdout
        )
        self.assertEqual((first["imported"], second["imported"]), (1, 0))

        changed = self.record(price=2_000_000, payload="b" * 64)
        self.write_records(changed)
        self.command(
            "import-jsonl", "--db", str(self.database), "--input", str(self.input), "--provider", "fixture"
        )
        status = json.loads(self.command("status", "--db", str(self.database), "--json").stdout)
        self.assertEqual(status["counts"]["listings"], 1)
        self.assertEqual(status["counts"]["listing_observations"], 2)

        self.command("export-csv", "--db", str(self.database), "--output", str(self.output))
        with self.output.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual(tuple(rows[0]), CSV_COLUMNS)
        self.assertEqual(rows[0]["current_price_micros"], "2000000")
        self.assertEqual(rows[0]["observed_at"], changed["observed_at"])
        self.assertEqual(rows[0]["source_run_id"], changed["source_run_id"])

    def test_future_version_is_rejected_without_database_mutation(self) -> None:
        """Reject a future owner version before applying local PRAGMAs or writes."""
        connection = sqlite3.connect(self.database)
        connection.execute("PRAGMA user_version=99")
        connection.execute("CREATE TABLE future_owner(value TEXT)")
        connection.commit()
        connection.close()
        before = hashlib.sha256(self.database.read_bytes()).hexdigest()

        with self.assertRaisesRegex(DomainOpportunityStoreError, "newer"):
            DomainOpportunityStore(self.database)

        after = hashlib.sha256(self.database.read_bytes()).hexdigest()
        self.assertEqual(after, before)
        connection = sqlite3.connect(self.database)
        self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 99)
        self.assertIsNotNone(connection.execute("SELECT name FROM sqlite_master WHERE name='future_owner'").fetchone())
        connection.close()

    def test_typed_successor_writer_apis_keep_provenance(self) -> None:
        """Expose stable typed metric, trend, and scoring boundaries to successors."""
        record = self.record()
        with DomainOpportunityStore(self.database, initialize=True) as store:
            with store.transaction():
                store.begin_source_run("fixture-run-1", "fixture", started_at="2026-08-21T10:00:00Z")
                self.assertTrue(store.upsert_listing_observation(record))
                self.assertTrue(
                    store.insert_keyword_metric(
                        KeywordMetric(
                            provider="fixture",
                            provider_listing_id="listing-1",
                            source_run_id="fixture-run-1",
                            source="keyword-planner",
                            metric_name="monthly_searches",
                            value=1200,
                            unit="count",
                            observed_at="2026-08-21T10:00:00Z",
                            payload_hash="c" * 64,
                        )
                    )
                )
                series_id = store.insert_trend_series(
                    TrendSeries(
                        provider="fixture",
                        provider_listing_id="listing-1",
                        source_run_id="fixture-run-1",
                        source="trends",
                        query="example",
                        geography="US",
                        timeframe="today 12-m",
                        observed_at="2026-08-21T10:00:00Z",
                        points=(("2026-08-20T10:00:00Z", 42),),
                    )
                )
                score_id = store.insert_candidate_score(
                    CandidateScore(
                        provider="fixture",
                        provider_listing_id="listing-1",
                        source_run_id="fixture-run-1",
                        model="exact-match-v1",
                        score_micros=750_000,
                        observed_at="2026-08-21T10:00:00Z",
                        components={
                            "demand": {"value_micros": 800_000, "weight_micros": 500_000}
                        },
                    )
                )
                store.complete_source_run("fixture-run-1", 1)
            self.assertGreater(series_id, 0)
            self.assertGreater(score_id, 0)
            self.assertEqual(store.status()["counts"]["keyword_metrics"], 1)
            self.assertEqual(store.status()["counts"]["trend_series"], 1)
            self.assertEqual(store.status()["counts"]["candidate_scores"], 1)

    def test_source_run_identity_cannot_move_between_providers(self) -> None:
        """Keep source-run provenance bound to its original provider."""
        with DomainOpportunityStore(self.database, initialize=True) as store:
            with store.transaction():
                store.begin_source_run("fixed-run", "fixture", started_at="2026-08-21T10:00:00Z")
            with self.assertRaisesRegex(DomainOpportunityStoreError, "another provider"):
                with store.transaction():
                    store.begin_source_run("fixed-run", "other", started_at="2026-08-21T11:00:00Z")
            provider = store.connection.execute(
                "SELECT provider FROM source_runs WHERE source_run_id='fixed-run'"
            ).fetchone()[0]
            self.assertEqual(provider, "fixture")


if __name__ == "__main__":
    unittest.main()
