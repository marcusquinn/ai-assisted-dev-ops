#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hermetic marketing performance identity, ingest, and recovery contracts."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from campaign_production_fixture import approved_manifest

SCRIPTS = Path(__file__).resolve().parents[1]
AGENTS = SCRIPTS.parent
REPO_ROOT = AGENTS.parent
HELPER = SCRIPTS / "performance-helper.py"
CAMPAIGN_HELPER = SCRIPTS / "campaign-helper.sh"
CAMPAIGN_PRODUCTION_HELPER = SCRIPTS / "campaign-production-helper.py"
AIDEVOPS = REPO_ROOT / "aidevops.sh"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "marketing-performance"
EVENT_SCHEMA = AGENTS / "schemas" / "marketing-performance-event.schema.json"
SUBJECT_SCHEMA = AGENTS / "schemas" / "marketing-subject.schema.json"


def write_reconciliation(path: Path, **action: object) -> None:
    """Write one reconciliation action without duplicating envelope setup."""
    path.write_text(
        json.dumps({"schema": "aidevops.marketing-performance-reconciliation/v1", "actions": [action]}),
        encoding="utf-8",
    )


@dataclass(frozen=True)
class EventSpec:
    """Behavior-neutral options for one normalized synthetic event."""

    event_type: str = "conversion"
    metric_id: str = "marketing.conversions.total"
    value: object = 1
    unit: str = "conversion"
    aggregation: str = "sum"
    currency: str | None = None
    occurred_at: str = "2026-08-08T12:00:00Z"
    correction_of: str | None = None
    subject: dict[str, object] | None = None
    scope: dict[str, object] | None = None
    confidence: str = "high"
    governance: dict[str, object] | None = None


@dataclass(frozen=True)
class BatchSpec:
    """Source checkpoint options for one normalized synthetic batch."""

    account_ref: str
    observed_at: str
    cursor: str
    coverage: str = "complete"
    missing_scopes: list[str] | None = None


class MarketingPerformanceIngestTests(unittest.TestCase):
    """Exercise only synthetic files and private temporary stores."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.environment = os.environ.copy()
        self.environment["AIDEVOPS_TEST_MODE"] = "1"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def command(
        self,
        *arguments: str,
        expected: int = 0,
        test_mode: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        environment = self.environment.copy()
        if not test_mode:
            environment.pop("AIDEVOPS_TEST_MODE", None)
        completed = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(HELPER), *arguments],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )
        self.assertEqual(expected, completed.returncode, completed.stderr)
        return completed

    def document(self, *arguments: str, expected: int = 0) -> dict[str, object]:
        completed = self.command(*arguments, expected=expected)
        return json.loads(completed.stdout)

    def initialize(self) -> dict[str, object]:
        return self.document("init", "--repo", str(self.repo))

    def ingest(
        self,
        adapter: str,
        fixture: str,
        *extra: str,
    ) -> dict[str, object]:
        return self.document(
            "ingest",
            "--adapter",
            adapter,
            "--input",
            str(FIXTURES / fixture),
            "--repo",
            str(self.repo),
            *extra,
        )

    def ingest_path(
        self,
        adapter: str,
        path: Path,
        *extra: str,
    ) -> dict[str, object]:
        return self.document(
            "ingest",
            "--adapter",
            adapter,
            "--input",
            str(path),
            "--repo",
            str(self.repo),
            *extra,
        )

    @staticmethod
    def normalized_event(
        source_event_id: str,
        **options: Any,
    ) -> dict[str, object]:
        spec = EventSpec(**options)
        return {
            "source_event_id": source_event_id,
            "revision": 1,
            "event_type": spec.event_type,
            "occurred_at": spec.occurred_at,
            "correction_of": spec.correction_of,
            "subject": spec.subject
            or {
                "kind": "aggregate",
                "identity_state": "not_applicable",
                "source_ref": None,
                "candidate_refs": [],
            },
            "scope": spec.scope or {"campaign_id": "c001-growth", "channel": "direct"},
            "measurement": {
                "metric_id": spec.metric_id,
                "value": spec.value,
                "unit": spec.unit,
                "aggregation": spec.aggregation,
                "currency": spec.currency,
            },
            "quality": {
                "confidence": spec.confidence,
                "completeness": "complete",
                "source_type": "api_export",
                "collected_by": "normalized-import",
                "verified_by": "synthetic-reviewer" if spec.confidence == "verified" else None,
            },
            "governance": spec.governance or {"consent": [], "suppression": None},
        }

    def write_batch(
        self,
        name: str,
        events: list[dict[str, object]],
        **options: Any,
    ) -> Path:
        spec = BatchSpec(**options)
        path = self.root / name
        path.write_text(
            json.dumps(
                {
                    "source": "normalized",
                    "account_ref": spec.account_ref,
                    "cursor": spec.cursor,
                    "observed_at": spec.observed_at,
                    "coverage": spec.coverage,
                    "missing_scopes": spec.missing_scopes or [],
                    "events": events,
                }
            ),
            encoding="utf-8",
        )
        return path

    @property
    def database(self) -> Path:
        return self.repo / "_performance" / "marketing" / "index" / "performance.sqlite"

    def query(self, sql: str, parameters: tuple[object, ...] = ()) -> list[sqlite3.Row]:
        connection = sqlite3.connect(self.database)
        connection.row_factory = sqlite3.Row
        try:
            return list(connection.execute(sql, parameters))
        finally:
            connection.close()

    def schema_validation(
        self,
        schema: Path,
        record: dict[str, object],
    ) -> subprocess.CompletedProcess[str]:
        document = self.root / "schema-record.json"
        document.write_text(json.dumps(record), encoding="utf-8")
        script = (
            "const fs=require('fs');"
            "const Ajv=require('ajv/dist/2020').default;"
            "const schema=JSON.parse(fs.readFileSync(process.argv[1]));"
            "const data=JSON.parse(fs.readFileSync(process.argv[2]));"
            "const validate=new Ajv({strict:false}).compile(schema);"
            "if(!validate(data)){console.error(JSON.stringify(validate.errors));process.exit(1)}"
        )
        return subprocess.run(  # nosec B603 -- fixed schema validator
            ["node", "-e", script, str(schema), str(document)],
            cwd=AGENTS,
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_schema(self, schema: Path, record: dict[str, object]) -> None:
        completed = self.schema_validation(schema, record)
        self.assertEqual(0, completed.returncode, completed.stderr)

    def assert_schema_rejected(self, schema: Path, record: dict[str, object]) -> None:
        completed = self.schema_validation(schema, record)
        self.assertNotEqual(0, completed.returncode, completed.stderr)

    def test_dry_run_is_non_mutating_and_fixture_adapters_are_fail_closed(self) -> None:
        validated = self.document(
            "validate",
            "--adapter",
            "social",
            "--input",
            str(FIXTURES / "social.json"),
            "--repo",
            str(self.repo),
        )
        self.assertTrue(validated["valid"])
        self.assertFalse((self.repo / "_performance").exists())
        for adapter in ("social", "analytics", "crm", "commerce", "outreach"):
            blocked = self.command(
                "ingest",
                "--adapter",
                adapter,
                "--input",
                str(FIXTURES / f"{adapter}.json"),
                "--repo",
                str(self.repo),
                expected=1,
                test_mode=False,
            )
            self.assertIn("fixture-only", blocked.stderr)
        self.assertFalse((self.repo / "_performance").exists())

        routed = subprocess.run(  # nosec B603 -- fixed repository CLI
            [
                "bash",
                str(AIDEVOPS),
                "performance",
                "status",
                "--json",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertEqual(0, routed.returncode, routed.stderr)
        routed_report = json.loads(routed.stdout[routed.stdout.index("{") :])
        self.assertEqual("uninitialized", routed_report["status"])

    def test_init_provisions_private_state_idempotently(self) -> None:
        first = self.initialize()
        second = self.initialize()
        self.assertEqual("ready", first["status"])
        self.assertEqual("ready", second["status"])
        private = self.repo / "_performance" / "marketing"
        self.assertEqual(0o700, stat.S_IMODE((private / "raw").stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE((private / "index").stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE(self.database.stat().st_mode))
        self.assertIn("marketing/raw/", (self.repo / "_performance" / ".gitignore").read_text(encoding="utf-8"))
        self.assertEqual(2, int(self.query("PRAGMA user_version")[0][0]))

    def test_init_rejects_symlinked_private_plane(self) -> None:
        outside = self.root / "outside-performance"
        outside.mkdir()
        (self.repo / "_performance").symlink_to(outside, target_is_directory=True)
        self.command("init", "--repo", str(self.repo), expected=1)
        self.assertFalse((outside / "marketing").exists())

    def test_missing_store_and_symlinked_io_fail_closed(self) -> None:
        self.initialize()
        self.database.unlink()
        self.command("list", "--repo", str(self.repo), expected=1)
        self.command("status", "--json", "--repo", str(self.repo), expected=1)
        self.command(
            "ingest",
            "--adapter",
            "social",
            "--input",
            str(FIXTURES / "social.json"),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertFalse(self.database.exists())

        corrupt_bytes = b"not-a-sqlite-database"
        self.database.write_bytes(corrupt_bytes)
        self.command("list", "--repo", str(self.repo), expected=1)
        self.command(
            "ingest",
            "--adapter",
            "social",
            "--input",
            str(FIXTURES / "social.json"),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertEqual(corrupt_bytes, self.database.read_bytes())

        shutil.rmtree(self.repo / "_performance")
        self.initialize()
        outside_sidecar = self.root / "outside-sidecar"
        outside_sidecar.write_text("preserve\n", encoding="utf-8")
        wal_path = Path(str(self.database) + "-wal")
        wal_path.unlink(missing_ok=True)
        wal_path.symlink_to(outside_sidecar)
        self.command("list", "--repo", str(self.repo), expected=1)
        self.assertEqual("preserve\n", outside_sidecar.read_text(encoding="utf-8"))
        self.assertTrue(wal_path.is_symlink())
        wal_path.unlink()

        input_link = self.root / "linked-input.json"
        input_link.symlink_to(FIXTURES / "social.json")
        self.command(
            "ingest",
            "--adapter",
            "social",
            "--input",
            str(input_link),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertEqual(0, len(self.query("SELECT record_ref FROM events")))

        outside = self.root / "outside-raw"
        outside.mkdir()
        raw_source = self.repo / "_performance" / "marketing" / "raw" / "normalized"
        raw_source.symlink_to(outside, target_is_directory=True)
        batch = self.write_batch(
            "raw-symlink.json",
            [self.normalized_event("raw-symlink")],
            account_ref="raw-symlink",
            observed_at="2026-08-12T12:00:00Z",
            cursor="raw-symlink",
        )
        self.command(
            "ingest",
            "--adapter",
            "normalized",
            "--input",
            str(batch),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertEqual([], list(outside.iterdir()))

    def test_schema_v1_store_migrates_additively(self) -> None:
        self.initialize()
        before = self.write_batch(
            "pre-migration.json",
            [self.normalized_event("pre-migration")],
            account_ref="migration-primary",
            observed_at="2026-08-11T12:00:00Z",
            cursor="pre-migration",
        )
        self.assertEqual(1, self.ingest_path("normalized", before)["accepted"])
        connection = sqlite3.connect(self.database)
        connection.executescript(
            """
            DROP TRIGGER events_no_update;
            DROP TRIGGER events_no_delete;
            ALTER TABLE events RENAME TO events_v2;
            CREATE TABLE events AS SELECT
                record_ref,event_ref,source,account_ref,revision,correction_ref,
                event_type,occurred_at,observed_at,recorded_at,subject_id,
                subject_kind,identity_state,campaign_id,channel,creative_id,
                touchpoint_id,outcome_id,metric_id,value_text,unit,aggregation,
                currency,period_start,period_end,confidence,completeness,source_type,collected_by,
                evidence_ref,payload_fingerprint
            FROM events_v2;
            DROP TABLE events_v2;
            PRAGMA user_version=1;
            """
        )
        connection.close()
        migrated = self.initialize()
        self.assertEqual(2, migrated["store_schema_version"])
        columns = {row[1] for row in self.query("PRAGMA table_info(events)")}
        self.assertTrue(
            {
                "period_start",
                "period_end",
                "dimensions_json",
                "source_observed_at",
                "source_recorded_at",
            }
            <= columns
        )
        self.assertEqual(1, len(self.query("SELECT record_ref FROM events")))
        replay = self.ingest_path("normalized", before)
        self.assertEqual(1, replay["duplicates"])
        self.assertTrue(replay["exact_replay"])
        path = self.write_batch(
            "post-migration.json",
            [self.normalized_event("post-migration")],
            account_ref="migration-primary",
            observed_at="2026-08-12T12:00:00Z",
            cursor="post-migration",
        )
        self.assertEqual(1, self.ingest_path("normalized", path)["accepted"])
        self.assertEqual(2, len(self.query("SELECT record_ref FROM events")))

    def test_all_source_classes_ingest_without_direct_identifiers(self) -> None:
        self.initialize()
        campaign = self.document(
            "ingest-campaign",
            "--campaign-id",
            "c001-growth",
            "--results",
            str(FIXTURES / "campaign-results.md"),
            "--repo",
            str(self.repo),
        )
        self.assertEqual(7, campaign["accepted"])
        precise_campaign = self.root / "precise-campaign-results.md"
        precise_campaign.write_text(
            (FIXTURES / "campaign-results.md")
            .read_text(encoding="utf-8")
            .replace("# Campaign Results: c001-growth", "# Campaign Results: c002-precision")
            .replace("| ROI | 125% |", "| ROI | 12.3456789012345678901234567891% |"),
            encoding="utf-8",
        )
        second_campaign = self.document(
            "ingest-campaign",
            "--campaign-id",
            "c002-precision",
            "--results",
            str(precise_campaign),
            "--repo",
            str(self.repo),
        )
        self.assertEqual(7, second_campaign["accepted"])
        isolated_campaign = self.document(
            "ingest-campaign",
            "--campaign-id",
            "c001-growth",
            "--account-ref",
            "c001-secondary",
            "--results",
            str(FIXTURES / "campaign-results.md"),
            "--repo",
            str(self.repo),
        )
        self.assertEqual(7, isolated_campaign["accepted"])
        expected = {
            "social": ("social.json", 2),
            "analytics": ("analytics.json", 2),
            "crm": ("crm.json", 3),
            "commerce": ("commerce.json", 4),
            "outreach": ("outreach.json", 3),
        }
        for adapter, (fixture, count) in expected.items():
            self.assertEqual(count, self.ingest(adapter, fixture)["accepted"])
        status = self.document(
            "status",
            "--json",
            "--repo",
            str(self.repo),
            "--now",
            "1786212000",
        )
        self.assertEqual("ready", status["status"])
        self.assertEqual(8, status["summary"]["source_accounts"])
        self.assertEqual(35, status["summary"]["event_history"])
        listed = self.document("list", "--repo", str(self.repo))
        records = listed["records"]
        self.assertEqual(35, len(records))
        for record in records:
            self.assert_schema(EVENT_SCHEMA, record)
        serialized = json.dumps(records)
        for private_ref in (
            "synthetic-lead-alpha",
            "synthetic-buyer-alpha",
            "synthetic-contact-alpha",
            "receipt-001",
            "order-001",
        ):
            self.assertNotIn(private_ref, serialized)
        summary = (
            self.repo
            / "_performance"
            / "marketing"
            / "summaries"
            / "c001-growth"
            / "c001-growth.jsonl"
        )
        self.assertTrue(summary.is_file())
        secondary_summary = (
            self.repo
            / "_performance"
            / "marketing"
            / "summaries"
            / "c001-secondary"
            / "c001-growth.jsonl"
        )
        self.assertEqual(
            7,
            len(secondary_summary.read_text(encoding="utf-8").splitlines()),
        )
        ratio = next(
            record
            for record in records
            if record["measurement"]["metric_id"] == "marketing.clicks.rate"
        )
        self.assertIsInstance(ratio["measurement"]["value"], str)
        summary_records = [
            json.loads(line)
            for line in summary.read_text(encoding="utf-8").splitlines()
        ]
        summary_ratio = next(
            record
            for record in summary_records
            if record["metric"]["id"] == "marketing.clicks.rate"
        )
        self.assertIsInstance(summary_ratio["measurement"]["value"], float)
        precise_ratio = next(
            record
            for record in records
            if record["source"]["account_ref"] == "c002-precision"
            and record["measurement"]["metric_id"]
            == "marketing.return_on_investment.ratio"
        )
        self.assertEqual(
            "0.123456789012345678901234567891",
            precise_ratio["measurement"]["value"],
        )
        precise_summary = (
            self.repo
            / "_performance"
            / "marketing"
            / "summaries"
            / "c002-precision"
            / "c002-precision.jsonl"
        )
        self.assertIn(
            '"value":0.123456789012345678901234567891',
            precise_summary.read_text(encoding="utf-8"),
        )
        rebuilt = self.document("rebuild", "--repo", str(self.repo))
        self.assertEqual(3, rebuilt["campaigns"])
        self.assertEqual(7, len(summary.read_text(encoding="utf-8").splitlines()))

        private_scope = {
            "campaign_id": "c001-growth",
            "channel": "direct",
            "dimensions": {"client": "alpha"},
        }
        for account_ref in ("dimension-primary", "dimension-secondary"):
            path = self.write_batch(
                f"{account_ref}.json",
                [self.normalized_event("private-dimension", scope=private_scope)],
                account_ref=account_ref,
                observed_at="2026-08-12T12:00:00Z",
                cursor=account_ref,
            )
            self.assertEqual(1, self.ingest_path("normalized", path)["accepted"])
        dimension_refs = [
            self.document(
                "list",
                "--account-ref",
                account_ref,
                "--repo",
                str(self.repo),
            )["records"][0]["scope"]["dimensions"]["client"]
            for account_ref in ("dimension-primary", "dimension-secondary")
        ]
        self.assertNotEqual(dimension_refs[0], dimension_refs[1])

    def test_adapter_errors_are_bounded_and_source_claims_fail_closed(self) -> None:
        self.initialize()
        spoofed = self.write_batch(
            "spoofed-source.json",
            [self.normalized_event("spoofed-source")],
            account_ref="spoofed-source",
            observed_at="2026-08-12T12:00:00Z",
            cursor="spoofed-source",
        )
        spoofed_document = json.loads(spoofed.read_text(encoding="utf-8"))
        spoofed_document["source"] = "social"
        spoofed.write_text(json.dumps(spoofed_document), encoding="utf-8")
        self.command(
            "ingest",
            "--adapter",
            "normalized",
            "--input",
            str(spoofed),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertEqual(0, len(self.query("SELECT source FROM sources")))

        oversized_number = self.root / "oversized-number.json"
        oversized_number.write_text(
            '{"source":"normalized","account_ref":"oversized-number",'
            '"cursor":"oversized-number","observed_at":"2026-08-12T12:00:00Z",'
            '"events":[{"value":' + ("9" * 5000) + "}]}",
            encoding="utf-8",
        )
        oversized = self.command(
            "ingest",
            "--adapter",
            "normalized",
            "--input",
            str(oversized_number),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertNotIn("Traceback", oversized.stderr)
        oversized_exponent = self.root / "oversized-exponent.json"
        oversized_exponent.write_text(
            '{"source":"normalized","account_ref":"oversized-exponent",'
            '"cursor":"oversized-exponent","observed_at":"2026-08-12T12:00:00Z",'
            '"events":[{"value":1e999999999999999999999999999999}]}',
            encoding="utf-8",
        )
        exponent = self.command(
            "ingest",
            "--adapter",
            "normalized",
            "--input",
            str(oversized_exponent),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertNotIn("Traceback", exponent.stderr)
        generic_campaign = self.document(
            "ingest",
            "--adapter",
            "campaign",
            "--input",
            str(FIXTURES / "campaign-results.md"),
            "--account-ref",
            "generic-campaign",
            "--repo",
            str(self.repo),
        )
        self.assertEqual(7, generic_campaign["accepted"])
        mismatch = self.command(
            "ingest-campaign",
            "--campaign-id",
            "c999-mismatch",
            "--results",
            str(FIXTURES / "campaign-results.md"),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertIn("does not match", mismatch.stderr)
        pii_campaign = self.root / "pii-campaign-results.md"
        pii_campaign.write_text(
            (FIXTURES / "campaign-results.md").read_text(encoding="utf-8")
            + "\nTelephone: +44/20/7946/0958\n",
            encoding="utf-8",
        )
        pii_result = self.command(
            "ingest-campaign",
            "--campaign-id",
            "c001-growth",
            "--results",
            str(pii_campaign),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertIn("contact destinations", pii_result.stderr)

        outreach = json.loads((FIXTURES / "outreach.json").read_text(encoding="utf-8"))
        valid_record = dict(outreach["records"][0])
        malformed = dict(outreach["records"][1])
        malformed["id"] = "malformed-unsubscribe"
        malformed["consent"] = {"state": "denied"}
        malformed_kind = dict(valid_record)
        malformed_kind["id"] = "malformed-kind"
        malformed_kind["kind"] = []
        outreach["records"] = [valid_record, malformed, malformed_kind]
        outreach["account_ref"] = "outreach-bounded-errors"
        outreach["cursor"] = "outreach-bounded-errors"
        malformed_path = self.root / "outreach-bounded-errors.json"
        malformed_path.write_text(json.dumps(outreach), encoding="utf-8")
        bounded = self.ingest_path("outreach", malformed_path)
        self.assertEqual(1, bounded["accepted"])
        self.assertEqual(2, bounded["quarantined"])
        self.assertFalse(bounded["cursor_advanced"])

        campaign_text = (FIXTURES / "campaign-results.md").read_text(encoding="utf-8")
        campaign_text = campaign_text.replace(
            "| Impressions | 1000 |",
            "| Impressions | 1000 |\n| Impressions | 1001 |",
        ).replace("| CTR (%) | 5% |", "| CTR (%) | |")
        campaign_text = campaign_text.replace("GBP 100.00", "JPY 100.00")
        campaign_path = self.root / "campaign-bounded-errors.md"
        campaign_path.write_text(campaign_text, encoding="utf-8")
        campaign = self.document(
            "ingest-campaign",
            "--campaign-id",
            "c001-growth",
            "--account-ref",
            "campaign-bounded-errors",
            "--results",
            str(campaign_path),
            "--repo",
            str(self.repo),
        )
        self.assertEqual(5, campaign["accepted"])
        self.assertEqual(1, campaign["quarantined"])
        self.assertFalse(campaign["cursor_advanced"])
        campaign_records = self.document(
            "list",
            "--account-ref",
            "campaign-bounded-errors",
            "--results",
            "--repo",
            str(self.repo),
        )["records"]
        cost = next(
            record
            for record in campaign_records
            if record["metric"]["id"] == "marketing.cost.amount"
        )
        self.assertEqual("JPY", cost["dimensions"]["currency"])
        source = self.query(
            "SELECT missing_scopes_json FROM sources WHERE account_ref='campaign-bounded-errors'"
        )[0][0]
        self.assertEqual('["ctr","impressions"]', source)

        self.command(
            "ingest-campaign",
            "--campaign-id",
            "../escape",
            "--results",
            str(FIXTURES / "campaign-results.md"),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertFalse((self.repo / "_performance" / "escape.md").exists())

    def test_phase1_backfill_is_dry_runnable_replayable_and_period_safe(self) -> None:
        fixture = FIXTURES / "phase1-results.jsonl"
        dry_run = self.document(
            "backfill",
            "--input",
            str(fixture),
            "--repo",
            str(self.repo),
            "--dry-run",
        )
        self.assertTrue(dry_run["valid"])
        self.assertFalse((self.repo / "_performance").exists())
        first = self.document(
            "backfill", "--input", str(fixture), "--repo", str(self.repo)
        )
        replay = self.document(
            "backfill", "--input", str(fixture), "--repo", str(self.repo)
        )
        self.assertEqual(2, first["accepted"])
        self.assertTrue(first["cursor_advanced"])
        self.assertEqual(2, replay["duplicates"])
        self.assertFalse(replay["cursor_advanced"])
        records = self.document(
            "list", "--source", "phase1", "--results", "--repo", str(self.repo)
        )["records"]
        self.assertEqual(2, len(records))
        revenue = next(record for record in records if record["metric"]["id"] == "marketing.revenue.gross")
        self.assertEqual("2026-08-01T00:00:00Z", revenue["measurement"]["period_start"])
        self.assertEqual("2026-08-31T23:59:59Z", revenue["measurement"]["period_end"])
        self.assertEqual("2026-08-31T23:59:59Z", revenue["measurement"]["observed_at"])
        self.assertEqual("2026-09-01T09:00:00Z", revenue["measurement"]["recorded_at"])
        self.assertEqual("GBP", revenue["dimensions"]["currency"])
        self.assertEqual("founders", revenue["dimensions"]["audience"])
        self.assertEqual("uk", revenue["dimensions"]["region"])
        self.assertRegex(
            revenue["dimensions"]["client"],
            r"^mkt-dim-v1:[a-f0-9]{64}$",
        )
        self.assertEqual(2, revenue["dimensions"]["cohort"])
        self.assertIs(True, revenue["dimensions"]["priority"])
        lead = next(
            record
            for record in records
            if record["metric"]["id"] == "marketing.leads.qualified"
        )
        self.assertEqual(
            "2026-08-31T20:00:00.500000Z",
            lead["measurement"]["source_event_at"],
        )
        self.assertNotIn("synthetic-legacy-lead", json.dumps(records))
        self.assertNotIn("Synthetic Client", json.dumps(records))

        corrupt = self.root / "phase1-corrupt.jsonl"
        malformed_phase1 = json.loads(
            fixture.read_text(encoding="utf-8").splitlines()[0]
        )
        malformed_phase1["subject"]["type"] = []
        malformed_aggregation = json.loads(
            fixture.read_text(encoding="utf-8").splitlines()[0]
        )
        malformed_aggregation["measurement"]["aggregation"] = []
        corrupt.write_text(
            fixture.read_text(encoding="utf-8")
            + json.dumps(malformed_phase1)
            + "\n"
            + json.dumps(malformed_aggregation)
            + "\n{invalid\n",
            encoding="utf-8",
        )
        partial = self.document(
            "backfill",
            "--input",
            str(corrupt),
            "--account-ref",
            "phase1-corrupt",
            "--repo",
            str(self.repo),
        )
        self.assertEqual(2, partial["accepted"])
        self.assertEqual(3, partial["quarantined"])
        self.assertFalse(partial["cursor_advanced"])

    def test_replay_account_isolation_and_same_revision_conflict(self) -> None:
        self.initialize()
        first = self.ingest("social", "social.json")
        replay = self.ingest("social", "social.json")
        isolated = self.ingest(
            "social", "social.json", "--account-ref", "social-secondary"
        )
        self.assertEqual(2, first["accepted"])
        self.assertEqual(2, replay["duplicates"])
        self.assertEqual(2, isolated["accepted"])
        self.assertEqual(4, len(self.query("SELECT record_ref FROM events")))
        self.assertEqual(4, len({row[0] for row in self.query("SELECT event_ref FROM events")}))

        corrections = self.ingest("normalized", "normalized-corrections.json")
        self.assertEqual(4, corrections["accepted"])
        effective = self.document(
            "list", "--repo", str(self.repo), "--source", "normalized"
        )["records"]
        self.assertEqual([2, 3], sorted(record["measurement"]["value"] for record in effective))
        history = self.document(
            "list", "--repo", str(self.repo), "--source", "normalized", "--history"
        )["records"]
        self.assertEqual(4, len(history))
        for record in history:
            self.assert_schema(EVENT_SCHEMA, record)
        correction_record = next(
            record for record in history if record["event"]["type"] == "correction"
        )
        non_correction = json.loads(json.dumps(history[0]))
        non_correction["event"]["correction_of"] = correction_record["event_ref"]
        self.assert_schema_rejected(EVENT_SCHEMA, non_correction)
        correction_without_target = json.loads(json.dumps(correction_record))
        correction_without_target["event"]["correction_of"] = None
        self.assert_schema_rejected(EVENT_SCHEMA, correction_without_target)
        imprecise_wire_value = json.loads(json.dumps(history[0]))
        imprecise_wire_value["measurement"]["value"] = 0.12345678901234568
        self.assert_schema_rejected(EVENT_SCHEMA, imprecise_wire_value)
        private_dimension = json.loads(json.dumps(history[0]))
        private_dimension["scope"]["dimensions"] = {
            "client": "private@example.test"
        }
        self.assert_schema_rejected(EVENT_SCHEMA, private_dimension)
        phone_dimension = json.loads(json.dumps(history[0]))
        phone_dimension["scope"]["dimensions"] = {"region": "1555_123_4567"}
        self.assert_schema_rejected(EVENT_SCHEMA, phone_dimension)
        numeric_phone_dimension = json.loads(json.dumps(history[0]))
        numeric_phone_dimension["scope"]["dimensions"] = {"region": 15551234567}
        self.assert_schema_rejected(EVENT_SCHEMA, numeric_phone_dimension)
        vanity_phone_dimension = json.loads(json.dumps(history[0]))
        vanity_phone_dimension["scope"]["dimensions"] = {"region": "1-800-flowers"}
        self.assert_schema_rejected(EVENT_SCHEMA, vanity_phone_dimension)
        reserved_dimension = json.loads(json.dumps(history[0]))
        reserved_dimension["scope"]["dimensions"] = {"channel": "secondary"}
        self.assert_schema_rejected(EVENT_SCHEMA, reserved_dimension)

        conflict_path = self.root / "conflict.json"
        conflict = json.loads((FIXTURES / "normalized-corrections.json").read_text(encoding="utf-8"))
        conflict["cursor"] = "normalized-conflicting-cursor"
        conflict["events"][1]["measurement"]["value"] = 9
        conflict_path.write_text(json.dumps(conflict), encoding="utf-8")
        result = self.document(
            "ingest",
            "--adapter",
            "normalized",
            "--input",
            str(conflict_path),
            "--repo",
            str(self.repo),
        )
        self.assertEqual(1, result["quarantined"])
        self.assertFalse(result["cursor_advanced"])
        self.assertEqual(4, len(self.query("SELECT record_ref FROM events WHERE source='normalized'")))

    def test_missing_scopes_and_out_of_order_batches_do_not_regress_checkpoints(self) -> None:
        self.initialize()
        newer = self.write_batch(
            "newer.json",
            [self.normalized_event("newer-event", value=10)],
            account_ref="monotonic-primary",
            observed_at="2026-08-10T12:00:00Z",
            cursor="cursor-newer",
        )
        first = self.ingest_path("normalized", newer)
        self.assertTrue(first["cursor_advanced"])
        source_before = self.query(
            "SELECT cursor_ref,last_observed_at,last_success_at FROM sources "
            "WHERE source='normalized' AND account_ref='monotonic-primary'"
        )[0]

        older = self.write_batch(
            "older.json",
            [self.normalized_event("older-event", value=9)],
            account_ref="monotonic-primary",
            observed_at="2026-08-09T12:00:00Z",
            cursor="cursor-older",
        )
        out_of_order = self.ingest_path("normalized", older)
        self.assertEqual(1, out_of_order["accepted"])
        self.assertFalse(out_of_order["cursor_advanced"])
        source_after = self.query(
            "SELECT cursor_ref,last_observed_at,last_success_at FROM sources "
            "WHERE source='normalized' AND account_ref='monotonic-primary'"
        )[0]
        self.assertEqual(tuple(source_before), tuple(source_after))

        duplicate_watermark = self.write_batch(
            "duplicate-watermark.json",
            [self.normalized_event("newer-event", value=10)],
            account_ref="monotonic-primary",
            observed_at="2026-08-10T12:00:00Z",
            cursor="cursor-duplicate-conflict",
        )
        duplicate_conflict = self.ingest_path("normalized", duplicate_watermark)
        self.assertEqual(1, duplicate_conflict["duplicates"])
        self.assertEqual(1, duplicate_conflict["quarantined"])
        self.assertFalse(duplicate_conflict["cursor_advanced"])
        self.assertFalse(duplicate_conflict["exact_replay"])

        same_watermark = self.write_batch(
            "same-watermark.json",
            [self.normalized_event("same-watermark-event", value=8)],
            account_ref="monotonic-primary",
            observed_at="2026-08-10T12:00:00Z",
            cursor="cursor-conflict",
        )
        checkpoint_conflict = self.ingest_path("normalized", same_watermark)
        self.assertEqual(1, checkpoint_conflict["accepted"])
        self.assertEqual(1, checkpoint_conflict["quarantined"])
        self.assertFalse(checkpoint_conflict["cursor_advanced"])
        self.assertIn(
            "same_watermark_cursor_conflict",
            [row[0] for row in self.query("SELECT reason FROM quarantine")],
        )

        validation_only = self.write_batch(
            "validation-missing-scopes.json",
            [self.normalized_event("validation-missing-scopes", value=10)],
            account_ref="validation-missing-scopes",
            observed_at="2026-08-11T12:00:00Z",
            cursor="validation-missing-scopes",
            missing_scopes=["analytics_detail"],
        )
        validation_report = self.document(
            "validate",
            "--adapter",
            "normalized",
            "--input",
            str(validation_only),
            "--repo",
            str(self.repo),
        )
        self.assertEqual(1, validation_report["accepted"])
        self.assertEqual(0, validation_report["quarantined"])
        self.assertEqual("partial", validation_report["coverage"])

        missing = self.write_batch(
            "missing-scopes.json",
            [
                self.normalized_event("missing-high", value=11),
                self.normalized_event("missing-verified", value=12, confidence="verified"),
            ],
            account_ref="monotonic-primary",
            observed_at="2026-08-11T12:00:00Z",
            cursor="cursor-partial",
            missing_scopes=["analytics_detail"],
        )
        partial = self.ingest_path("normalized", missing)
        self.assertEqual(1, partial["accepted"])
        self.assertEqual(1, partial["quarantined"])
        self.assertFalse(partial["cursor_advanced"])
        current = self.query(
            "SELECT status,coverage,missing_scopes_json,cursor_ref,last_observed_at,last_success_at "
            "FROM sources WHERE source='normalized' AND account_ref='monotonic-primary'"
        )[0]
        self.assertEqual("partial", current["status"])
        self.assertEqual('["analytics_detail"]', current["missing_scopes_json"])
        self.assertEqual(source_before["cursor_ref"], current["cursor_ref"])
        self.assertEqual("2026-08-11T12:00:00Z", current["last_observed_at"])
        self.assertEqual(source_before["last_success_at"], current["last_success_at"])
        records = self.document(
            "list", "--account-ref", "monotonic-primary", "--repo", str(self.repo)
        )["records"]
        accepted_partial = next(
            record for record in records if record["measurement"]["value"] == 11
        )
        self.assertEqual("medium", accepted_partial["quality"]["effective_confidence"])
        self.assertFalse(any(record["quality"]["effective_confidence"] == "verified" for record in records))

    def test_corrections_require_existing_compatible_targets(self) -> None:
        self.initialize()
        correction = self.normalized_event(
            "correction-event",
            value=3,
            event_type="correction",
            correction_of="target-event",
        )
        correction_path = self.write_batch(
            "correction-first.json",
            [correction],
            account_ref="correction-order",
            observed_at="2026-08-09T12:00:00Z",
            cursor="correction-first",
        )
        pending = self.ingest_path("normalized", correction_path)
        self.assertEqual(1, pending["quarantined"])
        self.assertEqual(
            "correction_target_pending",
            self.query("SELECT reason FROM quarantine")[0][0],
        )

        target_path = self.write_batch(
            "target-later.json",
            [self.normalized_event("target-event", value=1)],
            account_ref="correction-order",
            observed_at="2026-08-10T12:00:00Z",
            cursor="target-later",
        )
        self.assertEqual(1, self.ingest_path("normalized", target_path)["accepted"])
        replay = self.ingest_path("normalized", correction_path)
        self.assertEqual(1, replay["accepted"])
        self.assertFalse(replay["cursor_advanced"])
        effective = self.document(
            "list",
            "--account-ref",
            "correction-order",
            "--repo",
            str(self.repo),
        )["records"]
        self.assertEqual([3], [record["measurement"]["value"] for record in effective])
        status = self.document("status", "--json", "--repo", str(self.repo))
        self.assertEqual(0, status["summary"]["unresolved_quarantine"])

        mismatched = self.normalized_event(
            "mismatched-correction",
            value=4,
            event_type="correction",
            correction_of="target-event",
            scope={"campaign_id": "c002-other", "channel": "direct"},
        )
        mismatch_path = self.write_batch(
            "mismatched-correction.json",
            [mismatched],
            account_ref="correction-order",
            observed_at="2026-08-11T12:00:00Z",
            cursor="mismatched-correction",
        )
        mismatch = self.ingest_path("normalized", mismatch_path)
        self.assertEqual(1, mismatch["quarantined"])
        self.assertIn(
            "correction_target_mismatch",
            [row[0] for row in self.query("SELECT reason FROM quarantine")],
        )
        repeated = self.normalized_event(
            "second-correction",
            value=4,
            event_type="correction",
            correction_of="target-event",
        )
        repeated_path = self.write_batch(
            "second-correction.json",
            [repeated],
            account_ref="correction-order",
            observed_at="2026-08-12T12:00:00Z",
            cursor="second-correction",
        )
        self.assertEqual(1, self.ingest_path("normalized", repeated_path)["quarantined"])
        self.assertIn(
            "correction_target_already_corrected",
            [row[0] for row in self.query("SELECT reason FROM quarantine")],
        )

    def test_future_governance_and_invalid_semantics_fail_closed(self) -> None:
        self.initialize()
        subject = {
            "kind": "lead",
            "identity_state": "isolated",
            "source_ref": "future-consent-lead",
            "candidate_refs": [],
        }
        future = self.normalized_event(
            "future-consent",
            event_type="lead_created",
            metric_id="marketing.leads.created",
            unit="lead",
            subject=subject,
            governance={
                "consent": [
                    {
                        "purpose": "audience",
                        "state": "granted",
                        "lawful_basis": "synthetic-future-opt-in",
                        "effective_at": "2099-01-01T00:00:00Z",
                    }
                ],
                "suppression": {
                    "state": "clear",
                    "reason": "synthetic-future-clear",
                    "effective_at": "2099-01-01T00:00:00Z",
                },
            },
        )
        future_path = self.write_batch(
            "future-governance.json",
            [future],
            account_ref="governance-primary",
            observed_at="2026-08-11T12:00:00Z",
            cursor="future-governance",
        )
        self.assertEqual(1, self.ingest_path("normalized", future_path)["accepted"])
        future_subject = self.document("list", "--subjects", "--repo", str(self.repo))["records"][0]
        self.assertFalse(future_subject["audience_eligible"])
        self.assertEqual("consent_unknown", future_subject["eligibility_reason"])

        exact_decimal = self.write_batch(
            "exact-decimal-string.json",
            [
                self.normalized_event(
                    "exact-decimal-string",
                    value="0.123456789012345678901234567891",
                    scope={
                        "campaign_id": "c001-growth",
                        "channel": "direct",
                        "dimensions": {"cohort": 0.1},
                    },
                )
            ],
            account_ref="exact-decimal-string",
            observed_at="2026-08-11T13:00:00Z",
            cursor="exact-decimal-string",
        )
        self.assertEqual(1, self.ingest_path("normalized", exact_decimal)["accepted"])
        exact_record = self.document(
            "list",
            "--account-ref",
            "exact-decimal-string",
            "--repo",
            str(self.repo),
        )["records"][0]
        self.assertEqual(
            "0.123456789012345678901234567891",
            exact_record["measurement"]["value"],
        )
        self.assertEqual(0.1, exact_record["scope"]["dimensions"]["cohort"])
        self.assert_schema(EVENT_SCHEMA, exact_record)

        linked_subject = dict(subject)
        linked_subject["identity_state"] = "linked"
        invalid_period = self.normalized_event("invalid-fractional-period")
        invalid_period["measurement"]["period_start"] = "2026-08-12T12:00:00.500000Z"
        invalid_period["measurement"]["period_end"] = "2026-08-12T12:00:00Z"
        malformed_event_type = self.normalized_event("malformed-event-type")
        malformed_event_type["event_type"] = []
        oversized_revision = self.normalized_event("oversized-revision")
        oversized_revision["revision"] = 9_223_372_036_854_775_808
        reserved_dimension_event = self.normalized_event(
            "reserved-dimension",
            scope={
                "campaign_id": "c001-growth",
                "channel": "direct",
                "dimensions": {"channel": "secondary"},
            },
        )
        vanity_phone_event = self.normalized_event(
            "vanity-phone-dimension",
            scope={
                "campaign_id": "c001-growth",
                "channel": "direct",
                "dimensions": {"region": "1-800-flowers"},
            },
        )
        invalid_events = [
            self.normalized_event(
                "unsubscribe-without-governance",
                event_type="unsubscribe",
                metric_id="marketing.outreach.unsubscribes",
                unit="unsubscribe",
                subject=subject,
            ),
            self.normalized_event(
                "source-claimed-link",
                event_type="lead_created",
                metric_id="marketing.leads.created",
                unit="lead",
                subject=linked_subject,
            ),
            self.normalized_event(
                "metric-unit-mismatch",
                event_type="revenue",
                metric_id="marketing.revenue.gross",
                unit="conversion",
            ),
            self.normalized_event(
                "self-correction",
                event_type="correction",
                correction_of="self-correction",
            ),
            self.normalized_event(
                "non-correction-supersession",
                correction_of="future-consent",
            ),
            self.normalized_event(
                "imprecise-number",
                value=0.123456789012345678,
            ),
            invalid_period,
            malformed_event_type,
            oversized_revision,
            reserved_dimension_event,
            vanity_phone_event,
            self.normalized_event(
                "direct-dimension",
                scope={
                    "campaign_id": "c001-growth",
                    "channel": "direct",
                    "dimensions": {"email": "private@example.test"},
                },
            ),
            self.normalized_event(
                "direct-phone-dimension",
                scope={
                    "campaign_id": "c001-growth",
                    "channel": "direct",
                    "dimensions": {"region": "1555_123_4567"},
                },
            ),
            self.normalized_event(
                "direct-numeric-phone-dimension",
                scope={
                    "campaign_id": "c001-growth",
                    "channel": "direct",
                    "dimensions": {"region": 15551234567},
                },
            ),
            self.normalized_event(
                "direct-lawful-basis",
                subject=subject,
                governance={
                    "consent": [
                        {
                            "purpose": "audience",
                            "state": "granted",
                            "lawful_basis": "1555_123_4567",
                            "effective_at": "2026-08-11T00:00:00Z",
                        }
                    ],
                    "suppression": None,
                },
            ),
            self.normalized_event(
                "direct-suppression-reason",
                subject=subject,
                governance={
                    "consent": [],
                    "suppression": {
                        "state": "suppressed",
                        "reason": "1555_123_4567",
                        "effective_at": "2026-08-11T00:00:00Z",
                    },
                },
            ),
        ]
        invalid_path = self.write_batch(
            "invalid-contracts.json",
            invalid_events,
            account_ref="invalid-contracts",
            observed_at="2026-08-12T12:00:00Z",
            cursor="invalid-contracts",
        )
        invalid_text = invalid_path.read_text(encoding="utf-8").replace(
            '"value": 0.12345678901234568',
            '"value": 0.123456789012345678',
        )
        invalid_path.write_text(invalid_text, encoding="utf-8")
        invalid = self.ingest_path("normalized", invalid_path)
        self.assertEqual(0, invalid["accepted"])
        self.assertEqual(16, invalid["quarantined"])
        reasons = " ".join(error["reason"] for error in invalid["errors"])
        self.assertIn("unsubscribe events require", reasons)
        self.assertIn("owner reconciliation", reasons)
        self.assertIn("unit does not match", reasons)
        self.assertIn("cannot correct themselves", reasons)
        self.assertIn("only correction events may carry correction_of", reasons)
        self.assertIn("cannot be represented as an exact JSON number", reasons)
        self.assertIn("period start must not follow end", reasons)
        self.assertIn("event.event_type is unsupported", reasons)
        self.assertIn("bounded positive integer", reasons)
        self.assertIn("dedicated scope or measurement field", reasons)
        self.assertIn("cannot contain direct identifiers", reasons)
        self.assertIn("bounded lowercase alias", reasons)

    def test_partial_stale_and_ambiguous_sources_never_verify(self) -> None:
        self.initialize()
        partial = self.ingest("normalized", "normalized-partial.json")
        ambiguous = self.ingest("crm", "crm-ambiguous.json")
        self.assertEqual(1, partial["accepted"])
        self.assertEqual(1, partial["quarantined"])
        self.assertFalse(partial["cursor_advanced"])
        self.assertEqual(0, ambiguous["accepted"])
        self.assertEqual(1, ambiguous["quarantined"])
        status = self.document("status", "--json", "--repo", str(self.repo))
        self.assertEqual("partial", status["status"])
        partial_source = next(
            source for source in status["sources"] if source["account_ref"] == "normalized-partial"
        )
        self.assertFalse(partial_source["cursor_present"])
        record = self.document(
            "list",
            "--repo",
            str(self.repo),
            "--account-ref",
            "normalized-partial",
        )["records"][0]
        self.assertEqual("medium", record["quality"]["effective_confidence"])
        stale = self.document(
            "status", "--json", "--repo", str(self.repo), "--now", "2000000000"
        )
        self.assertTrue(any(source["stale"] for source in stale["sources"]))

    def test_consent_suppression_and_explicit_identity_reconciliation(self) -> None:
        self.initialize()
        self.ingest("crm", "crm.json")
        self.ingest("outreach", "outreach.json")
        subjects = self.document("list", "--subjects", "--repo", str(self.repo))["records"]
        self.assertEqual(4, len(subjects))
        self.assertEqual(3, sum(record["audience_eligible"] for record in subjects))
        for record in subjects:
            self.assert_schema(SUBJECT_SCHEMA, record)
        consent_subject = json.loads(
            json.dumps(next(record for record in subjects if record["consent"]))
        )
        consent_subject["consent"][0]["lawful_basis"] = "1555_123_4567"
        self.assert_schema_rejected(SUBJECT_SCHEMA, consent_subject)
        suppressed_subject = json.loads(
            json.dumps(next(record for record in subjects if record["suppression"]))
        )
        suppressed_subject["suppression"][0]["reason"] = "1555_123_4567"
        self.assert_schema_rejected(SUBJECT_SCHEMA, suppressed_subject)
        audience_path = self.root / "audience.jsonl"
        exported = self.document(
            "export",
            "--purpose",
            "audience",
            "--output",
            str(audience_path),
            "--repo",
            str(self.repo),
        )
        self.assertEqual(3, exported["records"])
        self.assertNotIn("synthetic-contact", audience_path.read_text(encoding="utf-8"))
        protected_output = self.root / "protected-output.jsonl"
        protected_output.write_text("preserve\n", encoding="utf-8")
        output_link = self.root / "linked-output.jsonl"
        output_link.symlink_to(protected_output)
        self.command(
            "export",
            "--purpose",
            "audience",
            "--output",
            str(output_link),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertEqual("preserve\n", protected_output.read_text(encoding="utf-8"))
        dangling_output = self.root / "dangling-output.jsonl"
        dangling_output.symlink_to(self.root / "missing-output-target.jsonl")
        self.command(
            "export",
            "--purpose",
            "audience",
            "--output",
            str(dangling_output),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertTrue(dangling_output.is_symlink())
        outside_export = self.root / "outside-export"
        outside_export.mkdir()
        linked_parent = self.repo / "linked-export-parent"
        linked_parent.symlink_to(outside_export, target_is_directory=True)
        self.command(
            "export",
            "--purpose",
            "audience",
            "--output",
            str(linked_parent / "audience.jsonl"),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertFalse((outside_export / "audience.jsonl").exists())
        outside_nested = self.root / "outside-nested-export"
        outside_nested.mkdir()
        sibling_link = self.root / "linked-export-ancestor"
        sibling_link.symlink_to(outside_nested, target_is_directory=True)
        self.command(
            "export",
            "--purpose",
            "audience",
            "--output",
            str(sibling_link / "missing-parent" / "audience.jsonl"),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertFalse((outside_nested / "missing-parent" / "audience.jsonl").exists())

        leads = [record["subject_id"] for record in subjects if record["kind"] == "lead"]
        reconciliation = self.root / "reconciliation.json"
        write_reconciliation(
            reconciliation,
            action="link",
            canonical_subject_id=leads[0],
            member_subject_id=leads[1],
            effective_at="2026-08-09T00:00:00.500000Z",
            evidence_ref="owner-reviewed-synthetic-link",
        )
        self.document("reconcile", "--input", str(reconciliation), "--repo", str(self.repo))
        linked = self.document("list", "--subjects", "--repo", str(self.repo))["records"]
        self.assertEqual(3, len(linked))
        self.assertEqual(2, sum(record["audience_eligible"] for record in linked))

        conflicting = json.loads(reconciliation.read_text(encoding="utf-8"))
        conflicting["actions"][0]["canonical_subject_id"] = next(
            record["subject_id"]
            for record in subjects
            if record["subject_id"] not in leads
        )
        conflicting["actions"][0]["evidence_ref"] = "conflicting-owner-link"
        reconciliation.write_text(json.dumps(conflicting), encoding="utf-8")
        self.command(
            "reconcile",
            "--input",
            str(reconciliation),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertEqual(1, len(self.query("SELECT link_ref FROM identity_links")))

        write_reconciliation(
            reconciliation,
            action="split",
            canonical_subject_id=leads[0],
            member_subject_id=leads[1],
            effective_at="2026-08-09T00:00:00Z",
            evidence_ref="owner-reviewed-older-split",
        )
        self.document("reconcile", "--input", str(reconciliation), "--repo", str(self.repo))
        still_linked = self.document("list", "--subjects", "--repo", str(self.repo))["records"]
        self.assertEqual(3, len(still_linked))

        decision = json.loads(reconciliation.read_text(encoding="utf-8"))
        decision["actions"][0]["action"] = "split"
        decision["actions"][0]["effective_at"] = "2026-08-09T00:00:00.750000Z"
        decision["actions"][0]["evidence_ref"] = "owner-reviewed-newer-split"
        reconciliation.write_text(json.dumps(decision), encoding="utf-8")
        self.document("reconcile", "--input", str(reconciliation), "--repo", str(self.repo))
        split = self.document("list", "--subjects", "--repo", str(self.repo))["records"]
        self.assertEqual(4, len(split))

    def test_identity_cycles_are_rejected_and_legacy_ambiguity_cannot_verify(self) -> None:
        self.initialize()
        verified_events = [
            self.normalized_event(
                f"verified-cycle-{suffix}",
                confidence="verified",
                subject={
                    "kind": "lead",
                    "identity_state": "isolated",
                    "source_ref": f"synthetic-cycle-{suffix}",
                    "candidate_refs": [],
                },
            )
            for suffix in ("alpha", "beta")
        ]
        verified_path = self.write_batch(
            "verified-cycle.json",
            verified_events,
            account_ref="verified-cycle",
            observed_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            cursor="verified-cycle",
        )
        self.assertEqual(2, self.ingest_path("normalized", verified_path)["accepted"])
        records = self.document("list", "--repo", str(self.repo))["records"]
        self.assertTrue(
            any(record["quality"]["effective_confidence"] == "verified" for record in records)
        )
        subjects = self.document("list", "--subjects", "--repo", str(self.repo))["records"]
        leads = sorted(record["subject_id"] for record in subjects if record["kind"] == "lead")
        reconciliation_path = self.root / "cycle-reconciliation.json"

        def reconcile(canonical: str, member: str, evidence: str, expected: int = 0) -> None:
            reconciliation_path.write_text(
                json.dumps(
                    {
                        "schema": "aidevops.marketing-performance-reconciliation/v1",
                        "actions": [
                            {
                                "action": "link",
                                "canonical_subject_id": canonical,
                                "member_subject_id": member,
                                "effective_at": "2026-08-09T00:00:00.500000Z",
                                "evidence_ref": evidence,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            self.command(
                "reconcile",
                "--input",
                str(reconciliation_path),
                "--repo",
                str(self.repo),
                expected=expected,
            )

        reconcile(leads[0], leads[1], "owner-reviewed-forward-link")
        reverse_document = json.loads(reconciliation_path.read_text(encoding="utf-8"))
        reverse_document["actions"][0].update(
            {
                "canonical_subject_id": leads[1],
                "member_subject_id": leads[0],
                "effective_at": "2026-08-09T00:00:00Z",
                "evidence_ref": "owner-reviewed-cyclic-link",
            }
        )
        reconciliation_path.write_text(json.dumps(reverse_document), encoding="utf-8")
        rejected = self.command(
            "reconcile",
            "--input",
            str(reconciliation_path),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertIn("cyclic link graph", rejected.stderr)
        self.assertEqual(1, len(self.query("SELECT link_ref FROM identity_links")))

        connection = sqlite3.connect(self.database)
        try:
            connection.execute(
                "INSERT INTO identity_links VALUES(?,?,?,?,?,?,?)",
                (
                    "mkt-link-v1:sha256:" + "f" * 64,
                    "link",
                    leads[1],
                    leads[0],
                    "mkt-evidence-v1:sha256:" + "e" * 64,
                    "2026-08-09T00:00:00Z",
                    "2026-08-09T00:00:01Z",
                ),
            )
            connection.commit()
        finally:
            connection.close()
        ambiguous_records = [
            record
            for record in self.document("list", "--repo", str(self.repo))["records"]
            if record["subject"]["identity_state"] == "ambiguous"
        ]
        self.assertTrue(ambiguous_records)
        self.assertFalse(
            any(
                record["quality"]["effective_confidence"] == "verified"
                for record in ambiguous_records
            )
        )
        ambiguous_subjects = [
            record
            for record in self.document("list", "--subjects", "--repo", str(self.repo))[
                "records"
            ]
            if record["identity_state"] == "ambiguous"
        ]
        self.assertTrue(ambiguous_subjects)
        self.assertFalse(any(record["audience_eligible"] for record in ambiguous_subjects))

    def test_quarantine_reconciliation_and_expired_lease_repair_are_append_only(self) -> None:
        self.initialize()
        self.ingest("normalized", "normalized-partial.json")
        quarantine_ref = str(self.query("SELECT quarantine_ref FROM quarantine")[0][0])
        reconciliation = self.root / "quarantine-reconciliation.json"
        reconciliation.write_text(
            json.dumps(
                {
                    "schema": "aidevops.marketing-performance-reconciliation/v1",
                    "actions": [
                        {
                            "action": "resolve_quarantine",
                            "quarantine_ref": quarantine_ref,
                            "resolution": "discarded",
                            "effective_at": "2099-08-09T00:00:00Z",
                            "evidence_ref": "owner-reviewed-invalid-currency",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        self.document("reconcile", "--input", str(reconciliation), "--repo", str(self.repo))
        status = self.document("status", "--json", "--repo", str(self.repo))
        self.assertEqual(1, status["summary"]["unresolved_quarantine"])

        decision = json.loads(reconciliation.read_text(encoding="utf-8"))
        decision["actions"][0]["note"] = "unsupported-private-field"
        reconciliation.write_text(json.dumps(decision), encoding="utf-8")
        self.command(
            "reconcile",
            "--input",
            str(reconciliation),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertEqual(1, len(self.query("SELECT reconciliation_ref FROM reconciliations")))

        del decision["actions"][0]["note"]
        decision["actions"][0]["evidence_ref"] = "private@example.test"
        reconciliation.write_text(json.dumps(decision), encoding="utf-8")
        self.command(
            "reconcile",
            "--input",
            str(reconciliation),
            "--repo",
            str(self.repo),
            expected=1,
        )
        self.assertEqual(1, len(self.query("SELECT reconciliation_ref FROM reconciliations")))

        decision["actions"][0]["evidence_ref"] = "owner-reviewed-invalid-currency"
        decision["actions"][0]["effective_at"] = "2026-08-09T00:00:00Z"
        reconciliation.write_text(json.dumps(decision), encoding="utf-8")
        self.document("reconcile", "--input", str(reconciliation), "--repo", str(self.repo))
        status = self.document("status", "--json", "--repo", str(self.repo))
        self.assertEqual(0, status["summary"]["unresolved_quarantine"])
        connection = sqlite3.connect(self.database)
        connection.execute(
            "INSERT INTO leases VALUES(?,?,?,?,?)",
            ("social", "expired-account", "expired-token", 1, 2),
        )
        connection.commit()
        connection.close()
        repaired = self.document("repair", "--repo", str(self.repo))
        self.assertEqual(1, repaired["expired_leases_removed"])
        self.assertFalse(repaired["history_rewritten"])

    def _write_campaign_manifest(self, campaign: Path) -> None:
        output = campaign / "creative" / "post.txt"
        output.parent.mkdir(parents=True)
        output.write_text("Reviewed synthetic launch post", encoding="utf-8")
        digest = "sha256:" + hashlib.sha256(output.read_bytes()).hexdigest()
        source_snapshot = "sha256:" + "c" * 64
        brief_document = {
            "schema_version": 1,
            "brief_id": "brief:c001-growth",
            "campaign_id": "c001-growth",
            "revision": 1,
            "source_snapshot_sha256": source_snapshot,
            "objective": {"metric": "marketing.conversions.total", "target": "10"},
            "audience_insight": {
                "segment": "synthetic-audience",
                "pain": "slow review",
                "outcome": "faster review",
            },
            "message": {
                "positioning": "Evidence-backed review",
                "hook": "Review faster",
                "story": "Synthetic campaign story",
                "cta": "Review the evidence",
            },
            "creative": {
                "copy_direction": "Use synthetic copy",
                "script_direction": "",
                "shot_direction": "",
                "visual_direction": "Use synthetic visuals",
                "audio_direction": "",
            },
            "brand_references": ["DESIGN.md"],
            "claims": [
                {
                    "claim": "Synthetic claim",
                    "evidence_reference": "synthetic-evidence",
                    "approval_status": "approved",
                }
            ],
            "authenticity": {
                "synthetic_people_or_voice": False,
                "testimonial_or_ugc_style": False,
                "source_requirements": [],
                "consent_requirements": [],
                "disclosure_requirements": [],
            },
            "review": {
                "criteria": ["Synthetic review criterion"],
                "owner": "synthetic-reviewer",
                "status": "required",
            },
            "lifecycle": {"status": "brief_ready", "asset_evidence": []},
        }
        brief = campaign / "drafts" / "creative-brief-v1.json"
        brief.parent.mkdir(parents=True, exist_ok=True)
        brief.write_text(
            json.dumps(brief_document),
            encoding="utf-8",
        )
        brief_digest = "sha256:" + hashlib.sha256(
            json.dumps(
                brief_document,
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
        ).hexdigest()
        input_snapshot_payload = {
            "brief": brief_digest,
            "channel": "twitter",
            "variant": 1,
            "asset_class": "writing",
        }
        input_snapshot = "sha256:" + hashlib.sha256(
            json.dumps(
                input_snapshot_payload,
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
        ).hexdigest()
        manifest = campaign / "drafts" / "production-manifests" / "twitter-v1.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(
            json.dumps(approved_manifest("c001-growth", input_snapshot, digest)),
            encoding="utf-8",
        )

    def test_campaign_promotion_rejects_symlinked_results(self) -> None:
        campaign = self.repo / "_campaigns" / "launched" / "c001-growth"
        campaign.mkdir(parents=True)
        (campaign / "results.md").symlink_to(FIXTURES / "campaign-results.md")
        self._write_campaign_manifest(campaign)
        completed = subprocess.run(  # nosec B603 -- fixed local helper
            [
                "bash",
                str(CAMPAIGN_HELPER),
                "promote",
                "c001-growth",
                "--results",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("non-symlink", completed.stderr)
        self.assertFalse((self.repo / "_performance").exists())
        outside_learnings = self.root / "outside-learnings.md"
        outside_learnings.write_text("private learnings\n", encoding="utf-8")
        (campaign / "learnings.md").symlink_to(outside_learnings)
        learnings = subprocess.run(  # nosec B603 -- fixed local helper
            [
                "bash",
                str(CAMPAIGN_HELPER),
                "promote",
                "c001-growth",
                "--learnings",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, learnings.returncode)
        self.assertFalse((self.repo / "_knowledge").exists())
        traversal = subprocess.run(  # nosec B603 -- fixed local helper
            [
                "bash",
                str(CAMPAIGN_HELPER),
                "promote",
                "../launched/c001-growth",
                "--learnings",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, traversal.returncode)
        phone_id = subprocess.run(  # nosec B603 -- fixed local helper
            [
                "bash",
                str(CAMPAIGN_HELPER),
                "promote",
                "1555_123_4567",
                "--learnings",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, phone_id.returncode)

        (campaign / "learnings.md").unlink()
        (campaign / "learnings.md").write_text(
            "Contact private@example.test for reviewed learnings\n",
            encoding="utf-8",
        )
        private_learnings = subprocess.run(  # nosec B603 -- fixed local helper
            [
                "bash",
                str(CAMPAIGN_HELPER),
                "promote",
                "c001-growth",
                "--learnings",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, private_learnings.returncode)
        self.assertFalse((self.repo / "_knowledge").exists())
        (campaign / "learnings.md").write_text("reviewed learnings\n", encoding="utf-8")

        manifest = campaign / "drafts" / "production-manifests" / "twitter-v1.json"
        valid_manifest = json.loads(manifest.read_text(encoding="utf-8"))
        mismatched_manifest = json.loads(json.dumps(valid_manifest))
        mismatched_manifest["campaign_id"] = "c002-other"
        manifest.write_text(json.dumps(mismatched_manifest), encoding="utf-8")
        mismatched_eligibility = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, mismatched_eligibility.returncode)
        self.assertNotIn("Traceback", mismatched_eligibility.stderr)
        cross_bound_manifest = json.loads(json.dumps(valid_manifest))
        cross_bound_manifest["brief_id"] = "brief:c002-other"
        cross_bound_manifest["job_id"] = "job:c002-other:x:v1"
        manifest.write_text(json.dumps(cross_bound_manifest), encoding="utf-8")
        cross_bound_eligibility = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, cross_bound_eligibility.returncode)
        self.assertNotIn("Traceback", cross_bound_eligibility.stderr)
        incomplete_manifest = json.loads(json.dumps(valid_manifest))
        incomplete_manifest.pop("revision")
        incomplete_manifest["outputs"][0].pop("media_type")
        manifest.write_text(json.dumps(incomplete_manifest), encoding="utf-8")
        incomplete_eligibility = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, incomplete_eligibility.returncode)
        self.assertNotIn("Traceback", incomplete_eligibility.stderr)
        invalid_execution = json.loads(json.dumps(valid_manifest))
        invalid_execution["execution"] = {}
        manifest.write_text(json.dumps(invalid_execution), encoding="utf-8")
        invalid_execution_eligibility = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, invalid_execution_eligibility.returncode)
        self.assertNotIn("Traceback", invalid_execution_eligibility.stderr)
        invalid_variant = json.loads(json.dumps(valid_manifest))
        invalid_variant["variant_id"] = "v0x"
        manifest.write_text(json.dumps(invalid_variant), encoding="utf-8")
        invalid_variant_eligibility = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, invalid_variant_eligibility.returncode)
        self.assertNotIn("Traceback", invalid_variant_eligibility.stderr)
        malformed_manifest = json.loads(json.dumps(valid_manifest))
        malformed_manifest["lifecycle"]["status"] = []
        manifest.write_text(json.dumps(malformed_manifest), encoding="utf-8")
        malformed_eligibility = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, malformed_eligibility.returncode)
        self.assertNotIn("Traceback", malformed_eligibility.stderr)
        manifest.write_text(json.dumps(valid_manifest), encoding="utf-8")
        brief_path = campaign / "drafts" / "creative-brief-v1.json"
        valid_brief = json.loads(brief_path.read_text(encoding="utf-8"))
        stale_brief = json.loads(json.dumps(valid_brief))
        stale_brief["source_snapshot_sha256"] = "sha256:" + "d" * 64
        brief_path.write_text(json.dumps(stale_brief), encoding="utf-8")
        stale_eligibility = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, stale_eligibility.returncode)
        self.assertNotIn("Traceback", stale_eligibility.stderr)
        cross_campaign_brief = json.loads(json.dumps(valid_brief))
        cross_campaign_brief["campaign_id"] = "c002-other"
        brief_path.write_text(json.dumps(cross_campaign_brief), encoding="utf-8")
        cross_campaign_brief_eligibility = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, cross_campaign_brief_eligibility.returncode)
        self.assertNotIn("Traceback", cross_campaign_brief_eligibility.stderr)
        incomplete_brief = json.loads(json.dumps(valid_brief))
        incomplete_brief.pop("brand_references")
        brief_path.write_text(json.dumps(incomplete_brief), encoding="utf-8")
        incomplete_brief_eligibility = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, incomplete_brief_eligibility.returncode)
        self.assertNotIn("Traceback", incomplete_brief_eligibility.stderr)
        malformed_brief = json.loads(json.dumps(valid_brief))
        malformed_brief["lifecycle"] = "brief_ready"
        brief_path.write_text(json.dumps(malformed_brief), encoding="utf-8")
        malformed_brief_eligibility = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, malformed_brief_eligibility.returncode)
        self.assertNotIn("Traceback", malformed_brief_eligibility.stderr)
        brief_path.write_text(json.dumps(valid_brief), encoding="utf-8")
        outside_manifest = self.root / "outside-production-manifest.json"
        outside_manifest.write_text(json.dumps(valid_manifest), encoding="utf-8")
        manifest.unlink()
        manifest.symlink_to(outside_manifest)
        symlinked_eligibility = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, symlinked_eligibility.returncode)
        self.assertNotIn("Traceback", symlinked_eligibility.stderr)
        manifest.unlink()
        manifest.write_text(json.dumps(valid_manifest), encoding="utf-8")

        creative = campaign / "creative"
        outside_creative = self.root / "outside-eligibility-creative"
        creative.rename(outside_creative)
        creative.symlink_to(outside_creative, target_is_directory=True)
        symlinked_output_parent_eligibility = subprocess.run(  # nosec B603 -- local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, symlinked_output_parent_eligibility.returncode)
        self.assertNotIn("Traceback", symlinked_output_parent_eligibility.stderr)
        creative.unlink()
        outside_creative.rename(creative)

        drafts = campaign / "drafts"
        outside_drafts = self.root / "outside-eligibility-drafts"
        drafts.rename(outside_drafts)
        drafts.symlink_to(outside_drafts, target_is_directory=True)
        symlinked_drafts_eligibility = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(CAMPAIGN_PRODUCTION_HELPER), "eligibility", str(campaign)],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, symlinked_drafts_eligibility.returncode)
        self.assertNotIn("Traceback", symlinked_drafts_eligibility.stderr)
        drafts.unlink()
        outside_drafts.rename(drafts)

        launched_root = campaign.parent
        outside_launched = self.root / "outside-launched"
        launched_root.rename(outside_launched)
        launched_root.symlink_to(outside_launched, target_is_directory=True)
        ancestor = subprocess.run(  # nosec B603 -- fixed local helper
            [
                "bash",
                str(CAMPAIGN_HELPER),
                "promote",
                "c001-growth",
                "--learnings",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, ancestor.returncode)
        self.assertFalse((self.repo / "_knowledge").exists())

    def test_campaign_launch_rejects_symlinked_destination(self) -> None:
        campaign = self.repo / "_campaigns" / "active" / "c001-growth"
        campaign.mkdir(parents=True)
        self._write_campaign_manifest(campaign)
        outside_launched = self.root / "outside-launch-destination"
        outside_launched.mkdir()
        launched = self.repo / "_campaigns" / "launched"
        launched.symlink_to(outside_launched, target_is_directory=True)
        completed = subprocess.run(  # nosec B603 -- fixed local helper
            [
                "bash",
                str(CAMPAIGN_HELPER),
                "launch",
                "c001-growth",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, completed.returncode)
        self.assertTrue(campaign.is_dir())
        self.assertEqual([], list(outside_launched.iterdir()))

    def test_campaign_promotion_preserves_markdown_and_adds_normalized_summary(self) -> None:
        campaign = self.repo / "_campaigns" / "launched" / "c001-growth"
        campaign.mkdir(parents=True)
        results_file = campaign / "results.md"
        shutil.copy2(FIXTURES / "campaign-results.md", results_file)
        fallback_text = "\n".join(
            line
            for line in results_file.read_text(encoding="utf-8").splitlines()
            if not line.startswith(("**Launched:**", "**Observed:**"))
        ) + "\n"
        results_file.write_text(fallback_text, encoding="utf-8")
        os.utime(results_file, (1786147200, 1786147200))
        self._write_campaign_manifest(campaign)
        completed = subprocess.run(  # nosec B603 -- fixed local helper
            [
                "bash",
                str(CAMPAIGN_HELPER),
                "promote",
                "c001-growth",
                "--results",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        legacy = self.repo / "_performance" / "marketing" / "c001-growth.md"
        summary = (
            self.repo
            / "_performance"
            / "marketing"
            / "summaries"
            / "c001-growth"
            / "c001-growth.jsonl"
        )
        self.assertEqual((campaign / "results.md").read_text(encoding="utf-8"), legacy.read_text(encoding="utf-8"))
        self.assertEqual(7, len(summary.read_text(encoding="utf-8").splitlines()))

        legacy.write_text("stale pre-commit prose\n", encoding="utf-8")
        time.sleep(1.1)
        recovered = subprocess.run(  # nosec B603 -- fixed local helper
            [
                "bash",
                str(CAMPAIGN_HELPER),
                "promote",
                "c001-growth",
                "--results",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertEqual(0, recovered.returncode, recovered.stderr)
        self.assertEqual(results_file.read_text(encoding="utf-8"), legacy.read_text(encoding="utf-8"))
        self.assertEqual(7, len(self.query("SELECT record_ref FROM events")))

        summary.write_text("{corrupt\n", encoding="utf-8")
        rebuilt = self.document("rebuild", "--repo", str(self.repo))
        self.assertEqual(1, rebuilt["campaigns"])
        self.assertEqual(7, len(summary.read_text(encoding="utf-8").splitlines()))

        valid_revision = (campaign / "results.md").read_text(encoding="utf-8").replace(
            "**Revision:** 1", "**Revision:** 2"
        ).replace(
            "| Impressions | 1000 |", "| Impressions | 1001 |"
        )
        (campaign / "results.md").write_text(valid_revision, encoding="utf-8")
        os.utime(campaign / "results.md", (1786147200, 1786147200))
        revised = subprocess.run(  # nosec B603 -- fixed local helper
            [
                "bash",
                str(CAMPAIGN_HELPER),
                "promote",
                "c001-growth",
                "--results",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertEqual(0, revised.returncode, revised.stderr)
        self.assertEqual(valid_revision, legacy.read_text(encoding="utf-8"))
        self.assertEqual(14, len(self.query("SELECT record_ref FROM events")))

        preserved = legacy.read_text(encoding="utf-8")
        (campaign / "results.md").write_text(fallback_text, encoding="utf-8")
        os.utime(campaign / "results.md", (1786147200, 1786147200))
        historical = subprocess.run(  # nosec B603 -- fixed local helper
            [
                "bash",
                str(CAMPAIGN_HELPER),
                "promote",
                "c001-growth",
                "--results",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, historical.returncode)
        self.assertEqual(preserved, legacy.read_text(encoding="utf-8"))

        changed = valid_revision.replace(
            "| Impressions | 1001 |", "| Impressions | 1002 |"
        )
        (campaign / "results.md").write_text(changed, encoding="utf-8")
        os.utime(campaign / "results.md", (1786147200, 1786147200))
        conflicted = subprocess.run(  # nosec B603 -- fixed local helper
            [
                "bash",
                str(CAMPAIGN_HELPER),
                "promote",
                "c001-growth",
                "--results",
                "--repo",
                str(self.repo),
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment,
        )
        self.assertNotEqual(0, conflicted.returncode)
        self.assertIn("quarantined", conflicted.stderr)
        self.assertEqual(preserved, legacy.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
