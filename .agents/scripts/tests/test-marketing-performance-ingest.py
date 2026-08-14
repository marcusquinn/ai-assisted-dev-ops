#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hermetic marketing Performance Plane ingest and privacy contract tests."""

from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / ".agents/scripts/performance-helper.py"
FIXTURES = ROOT / ".agents/scripts/tests/fixtures/marketing-performance"
EVENT_SCHEMA = ROOT / ".agents/schemas/marketing-performance-event.schema.json"
SUBJECT_SCHEMA = ROOT / ".agents/schemas/marketing-subject.schema.json"


class MarketingPerformanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def invoke(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        command = ["python3", str(HELPER), *arguments, "--repo", str(self.repo)]
        return subprocess.run(command, text=True, capture_output=True, check=False)  # nosec B603: fixed interpreter and helper

    def fixture(self, name: str) -> Path:
        return FIXTURES / f"{name}.json"

    def write_fixture(self, document: dict[str, object], name: str = "input.json") -> Path:
        path = Path(self.temp.name) / name
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def records(self, relative: str) -> list[dict[str, object]]:
        path = self.repo / "_performance/marketing" / relative
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]

    def test_schemas_are_strict_and_well_formed(self) -> None:
        event_schema = json.loads(EVENT_SCHEMA.read_text(encoding="utf-8"))
        subject_schema = json.loads(SUBJECT_SCHEMA.read_text(encoding="utf-8"))
        self.assertEqual(event_schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertFalse(event_schema["additionalProperties"])
        self.assertFalse(subject_schema["additionalProperties"])
        self.assertIn("source", event_schema["required"])
        self.assertIn("suppressions", subject_schema["required"])

    def test_all_initial_adapters_ingest_source_isolated_events(self) -> None:
        for adapter in ("campaign", "social", "analytics", "crm", "payment", "outreach"):
            result = self.invoke("ingest", "--adapter", adapter, "--input", str(self.fixture(adapter)))
            self.assertEqual(result.returncode, 0, result.stderr)
        events = self.records("raw/events.jsonl")
        self.assertEqual(len(events), 6)
        self.assertEqual(len({(item["source"]["provider"], item["source"]["account_id"]) for item in events}), 6)
        self.assertTrue(all(str(item["event_id"]).startswith("mpe_") for item in events))
        status = self.invoke("status")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertTrue(json.loads(status.stdout)["partial"])

    def test_replay_and_out_of_order_events_are_idempotent(self) -> None:
        fixture = json.loads(self.fixture("analytics").read_text(encoding="utf-8"))
        late = copy.deepcopy(fixture["events"][0])
        late["source_event_id"] = "conversion-late"
        late["occurred_at"] = "2026-08-01T00:00:00Z"
        fixture["events"].append(late)
        path = self.write_fixture(fixture)
        self.assertEqual(self.invoke("ingest", "--adapter", "analytics", "--input", str(path)).returncode, 0)
        self.assertEqual(self.invoke("ingest", "--adapter", "analytics", "--input", str(path)).returncode, 0)
        self.assertEqual(len(self.records("raw/events.jsonl")), 2)
        projection = self.records("projections/results.jsonl")[0]
        self.assertEqual(projection["measurement"]["value"], 8)
        self.assertEqual(len(projection["quality"]["evidence"]), 2)

    def test_legacy_campaign_markdown_remains_ingestible(self) -> None:
        results = Path(self.temp.name) / "results.md"
        results.write_text("""# Campaign Results: c001\n\n**Launched:** 2026-08-14\n\n| Metric | Value |\n|---|---|\n| Impressions | 100 |\n| CTR (%) | 5 |\n| Cost | GBP 20 |\n""", encoding="utf-8")
        result = self.invoke("ingest", "--adapter", "campaign", "--input", str(results), "--source-account", "c001", "--evidence-ref", "_campaigns/launched/c001/results.md")
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.records("raw/events.jsonl")
        self.assertEqual(len(events), 3)
        ctr = next(item for item in events if item["metric"]["id"] == "marketing.engagement.ctr")
        self.assertEqual(ctr["measurement"]["value"], 0.05)

    def test_refund_and_correction_append_without_rewriting_history(self) -> None:
        fixture = json.loads(self.fixture("payment").read_text(encoding="utf-8"))
        original_id = "mpe_" + hashlib.sha256("payment-fixture\0store-a\0sale-1".encode()).hexdigest()[:32]
        refund = copy.deepcopy(fixture["events"][0])
        refund.update({"source_event_id": "refund-1", "event_type": "refund"})
        refund["measurement"]["value"] = -25
        correction = copy.deepcopy(fixture["events"][0])
        correction.update({"source_event_id": "correction-1", "event_type": "correction", "correction_of": original_id})
        correction["measurement"]["value"] = 5
        fixture["events"].extend([refund, correction])
        path = self.write_fixture(fixture)
        result = self.invoke("ingest", "--adapter", "payment", "--input", str(path))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.records("raw/events.jsonl")), 3)
        self.assertEqual(self.records("projections/results.jsonl")[0]["measurement"]["value"], 105)

    def test_consent_suppression_and_identity_provenance_fail_closed(self) -> None:
        fixture = json.loads(self.fixture("crm").read_text(encoding="utf-8"))
        self.assertEqual(self.invoke("ingest", "--adapter", "crm", "--input", str(self.fixture("crm"))).returncode, 0)
        eligible = self.invoke("export", "--kind", "audience", "--scope", "outreach")
        self.assertEqual(len(json.loads(eligible.stdout)), 1)
        fixture["source"]["cursor"] = "crm:2"
        fixture["subjects"][0]["suppressions"] = [{"scope": "all", "status": "active", "reason": "unsubscribe", "source_ref": "fixture:unsubscribe", "effective_at": "2026-08-14T11:00:00Z"}]
        fixture["subjects"][0]["identity_changes"] = [{"action": "merge", "related_subject_ids": ["mps_" + "b" * 32], "evidence_ref": "fixture:review", "effective_at": "2026-08-14T11:00:00Z", "automatic": False}]
        suppressed = self.write_fixture(fixture, "suppressed.json")
        result = self.invoke("ingest", "--adapter", "crm", "--input", str(suppressed))
        self.assertEqual(result.returncode, 0, result.stderr)
        exported = self.invoke("export", "--kind", "audience", "--scope", "outreach")
        self.assertEqual(json.loads(exported.stdout), [])
        unsafe = copy.deepcopy(fixture)
        unsafe["subjects"][0]["identity_changes"][0]["automatic"] = True
        invalid = self.invoke("validate", "--adapter", "crm", "--input", str(self.write_fixture(unsafe, "unsafe.json")))
        self.assertNotEqual(invalid.returncode, 0)

    def test_invalid_currency_scope_and_raw_identifier_do_not_advance_cursor(self) -> None:
        fixture = json.loads(self.fixture("payment").read_text(encoding="utf-8"))
        del fixture["events"][0]["measurement"]["currency"]
        invalid = self.invoke("ingest", "--adapter", "payment", "--input", str(self.write_fixture(fixture)))
        self.assertNotEqual(invalid.returncode, 0)
        self.assertFalse((self.repo / "_performance/marketing/state/sources.json").exists())
        crm = json.loads(self.fixture("crm").read_text(encoding="utf-8"))
        crm["subjects"][0].pop("source_subject_hash")
        crm["subjects"][0]["email"] = "private@example.invalid"
        rejected = self.invoke("validate", "--adapter", "crm", "--input", str(self.write_fixture(crm, "private.json")))
        self.assertNotEqual(rejected.returncode, 0)

    def test_dry_run_and_corrupt_checkpoint_recovery_are_explicit(self) -> None:
        dry = self.invoke("ingest", "--adapter", "social", "--input", str(self.fixture("social")), "--dry-run")
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertFalse((self.repo / "_performance").exists())
        self.assertEqual(self.invoke("init").returncode, 0)
        state = self.repo / "_performance/marketing/state/sources.json"
        state.write_text("not-json\n", encoding="utf-8")
        failed = self.invoke("ingest", "--adapter", "social", "--input", str(self.fixture("social")))
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("source state", failed.stderr)


if __name__ == "__main__":
    unittest.main()
