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
        self.campaign = self.root / "c001"
        output = self.campaign / "creative" / "post.txt"
        output.parent.mkdir(parents=True)
        output.write_text("Reviewed launch post", encoding="utf-8")
        digest = "sha256:" + hashlib.sha256(output.read_bytes()).hexdigest()
        brief_document = {
            "schema_version": 1,
            "brief_id": "brief:c001",
            "campaign_id": "c001",
            "revision": 1,
            "source_snapshot_sha256": "sha256:" + "c" * 64,
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
        brief = self.campaign / "drafts" / "creative-brief-v1.json"
        brief.parent.mkdir(parents=True)
        brief.write_text(json.dumps(brief_document), encoding="utf-8")
        brief_digest = "sha256:" + hashlib.sha256(
            json.dumps(
                brief_document,
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
        ).hexdigest()
        input_snapshot = "sha256:" + hashlib.sha256(
            json.dumps(
                {
                    "asset_class": "writing",
                    "brief": brief_digest,
                    "channel": "twitter",
                    "variant": 1,
                },
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
        ).hexdigest()
        self.manifest = self.campaign / "drafts" / "production-manifests" / "twitter-v1.json"
        self.manifest.parent.mkdir(parents=True)
        self.manifest.write_text(json.dumps({
            "schema_version": 1, "job_id": "job:c001:twitter:v1", "campaign_id": "c001", "brief_id": "brief:c001",
            "channel": "twitter", "variant_id": "v1", "revision": 1, "input_snapshot_sha256": input_snapshot,
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

    def test_enqueue_rejects_symlinked_distribution_directory(self) -> None:
        outside = self.root / "outside-distribution"
        outside.mkdir()
        (self.campaign / "distribution").symlink_to(outside, target_is_directory=True)
        result = self._command("enqueue")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("directory is unsafe", result.stderr)
        self.assertEqual([], list(outside.iterdir()))

    def test_preview_rejects_symlinked_manifest_and_output_parent(self) -> None:
        outside_manifest = self.root / "outside-manifest.json"
        outside_manifest.write_bytes(self.manifest.read_bytes())
        self.manifest.unlink()
        self.manifest.symlink_to(outside_manifest)
        manifest_result = self._command("preview")
        self.assertNotEqual(manifest_result.returncode, 0)
        self.assertIn("non-symlink", manifest_result.stderr)
        self.manifest.unlink()
        self.manifest.write_bytes(outside_manifest.read_bytes())

        creative = self.campaign / "creative"
        outside_creative = self.root / "outside-creative"
        creative.rename(outside_creative)
        creative.symlink_to(outside_creative, target_is_directory=True)
        output_result = self._command("preview")
        self.assertNotEqual(output_result.returncode, 0)
        self.assertIn("symlink", output_result.stderr)


if __name__ == "__main__":
    unittest.main()
