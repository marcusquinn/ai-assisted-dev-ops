#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Producer/coordinator state transitions; no forge, worker or permission writes."""
import copy
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import integration_recovery as recovery  # noqa: E402


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db = recovery.connect(Path(self.tmp.name) / "private")
        self.addCleanup(self.db.close)
        self.request = {"schema": 1, "issue": 31265, "pr": 31269,
                        "reason": "adjacent_integration", "files": ["src/claim.sh"],
                        "evidence": "checkpoint caller requires shared claim integration",
                        "verification": ["bash existing-checkpoint-fixture.sh"]}
        self.envelope = {"repo": "owner/repo", "issue": 31265, "pr": 31269,
                         "attempt": "attempt-one", "session": "issue-31265", "head": "1" * 40,
                         "branch": "worker/issue-31265",
                         "brief": {"number": 31265, "state": "open", "title": "Recover checkpoint",
                                   "body": "## Files Scope\n- `src/caller.sh`", "assignees": [], "labels": []}}

    def output(self, request=None, event_type="text"):
        text = "BLOCKED: integration needs a brief correction\n" + recovery.MARKER + json.dumps(request or self.request)
        return json.dumps({"type": event_type, "part": {"text": text}})

    def state(self):
        return {"issue": copy.deepcopy(self.envelope["brief"]), "comments": [], "dependencies": []}

    def test_final_assistant_only(self):
        self.assertEqual(recovery.final_request(self.output()), self.request)
        for output in (self.output(event_type="tool"),
                       self.output() + '\n{"type":"text","text":"not a recovery request"}',
                       "BLOCKED:\n" + recovery.MARKER + json.dumps(self.request)):
            with self.subTest(output=output), self.assertRaises(ValueError):
                recovery.final_request(output)

    def test_no_authority_fields_or_unsafe_paths(self):
        for field, value in (("approval", True), ("permissions", "allow"),
                             ("files", ["../credential"]), ("files", ["src/*"]),
                             ("files", ["/private/path"])):
            request = dict(self.request, **{field: value})
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                recovery.final_request(self.output(request))

    def test_target_is_bound_by_runtime(self):
        for key in ("issue", "pr"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                recovery.capture(self.db, self.envelope, dict(self.request, **{key: 999}))

    def test_one_local_continuation_preserves_pr(self):
        request = recovery.final_request(self.output())
        first = recovery.capture(self.db, self.envelope, request)
        self.assertEqual(first["action"], "continue")
        self.envelope.update(attempt="attempt-two", head="2" * 40)
        second = recovery.capture(self.db, self.envelope, request)
        self.assertEqual(second, {"id": first["id"], "action": "coordinator"})
        record = recovery.show(self.db, first["id"])
        self.assertEqual((record["pr"], record["branch"], record["head"]),
                         (31269, "worker/issue-31265", "1" * 40))
        self.assertEqual(record["owner"], "pulse")
        self.assertNotIn("brief", record)

    def test_hard_boundary_never_gets_local_revision(self):
        hard = dict(self.request, reason="hard_boundary")
        first = recovery.capture(self.db, self.envelope, hard)
        self.assertEqual(first["action"], "coordinator")
        # Re-labelling the same event cannot manufacture a fresh local grant.
        self.assertEqual(recovery.capture(self.db, self.envelope, self.request)["action"], "coordinator")

    def test_corrected_brief_rearms_same_checkpoint(self):
        old = recovery.capture(self.db, self.envelope, self.request)
        self.envelope["brief"]["body"] += "\n- `src/claim.sh`"
        new = recovery.capture(self.db, self.envelope, self.request)
        self.assertNotEqual(old["id"], new["id"])
        self.assertEqual(recovery.show(self.db, new["id"])["pr"], 31269)

    def test_coordinator_decision_waits_for_relevant_revision(self):
        result = recovery.capture(self.db, self.envelope, dict(self.request, reason="hard_boundary"))
        state = self.state()
        self.assertIsNotNone(recovery.observe(self.db, result["id"], state))
        decision = {"wake": "brief_revision", "next_action": "authorized brief owner corrects scope, then reuse checkpoint helper",
                    "evidence": "hard boundary is explicit; no worker self-approval", "actor": "maintainer"}
        recovery.decide(self.db, result["id"], decision)
        self.assertIsNone(recovery.observe(self.db, result["id"], state))
        with self.assertRaises(sqlite3.IntegrityError):
            recovery.decide(self.db, result["id"], decision)
        state["issue"]["body"] += "\n- `src/claim.sh`"
        ready = recovery.observe(self.db, result["id"], state)
        self.assertEqual(ready["pr"], 31269)
        self.assertEqual(ready["branch"], "worker/issue-31265")
        # Decisions remain evidence, never execution or approval instructions.
        self.assertNotIn("approved", ready)

    def test_concurrent_owner_and_human_decision_remain_owned(self):
        for reason, wake in (("concurrent_owner", "owner_change"), ("human_decision", "human_decision")):
            request = dict(self.request, reason=reason, files=["src/" + reason + ".sh"])
            result = recovery.capture(self.db, self.envelope, request)
            self.assertEqual(result["action"], "coordinator")
            state = self.state()
            recovery.observe(self.db, result["id"], state)
            recovery.decide(self.db, result["id"], {"wake": wake, "next_action": "recheck the exact authorized decision or owner release",
                                                  "evidence": "specific external authority is unavailable; no substitute worker", "actor": "maintainer"})
            self.assertIsNone(recovery.observe(self.db, result["id"], state))
            state["comments"] = [{"body": "trusted owner changed", "created_at": "2026-01-01T00:00:00Z"}]
            self.assertIsNotNone(recovery.observe(self.db, result["id"], state))

    def test_resolved_objective_retires_queue_entry(self):
        result = recovery.capture(self.db, self.envelope, self.request)
        state = self.state()
        state["issue"]["state"] = "closed"
        self.assertIsNone(recovery.observe(self.db, result["id"], state))
        self.assertEqual(self.db.execute("SELECT status FROM requests").fetchone()[0], "resolved")


if __name__ == "__main__":
    unittest.main()
