#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hermetic contracts for reviewed campaign distribution queue bridging."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
HELPER = REPO_ROOT / ".agents" / "scripts" / "campaign-distribution-helper.py"


class CampaignDistributionBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.campaign = self.root / "campaign"
        output = self.campaign / "creative" / "post.txt"
        output.parent.mkdir(parents=True)
        output.write_text("Reviewed launch post", encoding="utf-8")
        digest = "sha256:" + hashlib.sha256(output.read_bytes()).hexdigest()
        self.manifest = self.campaign / "drafts" / "production-manifests" / "twitter-v1.json"
        self.manifest.parent.mkdir(parents=True)
        self.manifest.write_text(json.dumps({
            "schema_version": 1, "job_id": "job:c001:x:v1", "campaign_id": "c001", "brief_id": "brief:c001",
            "channel": "twitter", "variant_id": "v1", "revision": 1, "input_snapshot_sha256": "sha256:" + "a" * 64,
            "format": {"asset_class": "writing", "dimensions": "text", "duration_seconds": None}, "asset_inputs": [],
            "execution": {"owner": "content", "provider_route": None, "capability": "writing", "fallback": None, "status": "ready"},
            "authenticity": {"disclosure_requirements": [], "rights_requirements": [], "provenance": {"source": "owned", "recipe_sha256": "sha256:" + "b" * 64}, "rights_clearance": {"license": "owned", "consent": "documented", "territory": "global", "expires_at": None}},
            "review": {"criteria": ["reviewed"], "status": "approved", "decision_by": "owner", "decision_at": "2026-08-13T00:00:00Z"},
            "experiment": {"experiment_id": "e1", "hypothesis": "test"}, "lifecycle": {"status": "approved", "status_evidence": ["reviewed"]},
            "outputs": [{"path": "creative/post.txt", "sha256": digest, "media_type": "text/plain"}],
        }), encoding="utf-8")
        self.queue = self.root / "queue.sh"
        self.queue.write_text("#!/usr/bin/env bash\nprintf '%s\\n' '{\"operation_id\":\"ignored\",\"state\":\"draft\"}'\n", encoding="utf-8")
        self.queue.chmod(0o755)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _command(self, action: str, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(  # nosec B603
            [sys.executable, str(HELPER), action, "--campaign-dir", str(self.campaign), "--manifest", str(self.manifest), "--connection-id", "conn", "--account-id", "account", "--scheduled-at", "2000000000", "--queue-helper", str(self.queue), *extra],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_preview_is_dry_run_and_stable(self) -> None:
        first = self._command("preview")
        second = self._command("preview")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(json.loads(first.stdout)["operation_id"], json.loads(second.stdout)["operation_id"])
        self.assertFalse((self.campaign / "distribution").exists())

    def test_enqueue_is_idempotent_and_projects_calendar_state(self) -> None:
        database = self.root / "calendar.db"
        connection = sqlite3.connect(database)
        connection.execute("CREATE TABLE schedule (id INTEGER PRIMARY KEY, distribution_id TEXT, operation_id TEXT, operation_state TEXT, remote_id TEXT)")
        connection.execute("INSERT INTO schedule VALUES (1, '', '', '', '')")
        connection.commit()
        connection.close()
        first = self._command("enqueue", "--calendar-db", str(database), "--calendar-schedule-id", "1")
        second = self._command("enqueue", "--calendar-db", str(database), "--calendar-schedule-id", "1")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(json.loads(first.stdout)["operation_id"], json.loads(second.stdout)["operation_id"])
        record = next((self.campaign / "distribution").glob("*.json"))
        self.assertEqual(json.loads(record.read_text(encoding="utf-8"))["status"], "draft")
        connection = sqlite3.connect(database)
        state = connection.execute("SELECT operation_state FROM schedule WHERE id=1").fetchone()[0]
        connection.close()
        self.assertEqual(state, "draft")

    def test_unreviewed_manifest_cannot_enqueue(self) -> None:
        document = json.loads(self.manifest.read_text(encoding="utf-8"))
        document["review"]["status"] = "required"
        self.manifest.write_text(json.dumps(document), encoding="utf-8")
        result = self._command("enqueue")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("approved review", result.stderr)

    def test_unknown_queue_receipt_is_preserved(self) -> None:
        self.queue.write_text("#!/usr/bin/env bash\nprintf '%s\\n' '{\"operation_id\":\"ignored\",\"state\":\"unknown\"}'\n", encoding="utf-8")
        result = self._command("enqueue")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "unknown")


if __name__ == "__main__":
    unittest.main()
