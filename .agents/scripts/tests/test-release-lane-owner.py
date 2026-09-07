# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Real process lifecycle observations; no release/network operations."""

import importlib.util
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "lane_owner", Path(__file__).resolve().parents[1] / "release-lane-owner.py"
)
OWNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OWNER)


class OwnerTests(unittest.TestCase):
    def test_current_executor_is_live(self):
        identity = OWNER.capture(os.getpid())
        self.assertEqual(OWNER.observe(identity)["state"], "live")
        self.assertEqual(len(identity["host_id"]), 64)

    def test_process_observation_ignores_path(self):
        expected = OWNER.process_start(os.getpid())
        with patch.dict(os.environ, {"PATH": "/nonexistent"}):
            self.assertEqual(OWNER.process_start(os.getpid()), expected)

    def test_exited_real_process_is_dead(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            identity = OWNER.capture(child.pid)
        finally:
            child.terminate()
            child.wait(timeout=5)
        self.assertEqual(OWNER.observe(identity)["reason"], "process-absent")

    def test_pid_reuse_is_not_live(self):
        identity = OWNER.capture(os.getpid())
        identity["started_at"] = "a different process generation"
        self.assertEqual(OWNER.observe(identity)["reason"], "pid-reused")

    def test_foreign_and_legacy_identity_are_unknown(self):
        for identity in (None, {}, {"host_id": "foreign", "pid": os.getpid()}):
            self.assertEqual(OWNER.observe(identity)["state"], "unknown")

    def test_permission_is_unknown_not_dead(self):
        identity = OWNER.capture(os.getpid())
        with patch.object(OWNER.os, "kill", side_effect=PermissionError):
            self.assertEqual(OWNER.observe(identity)["state"], "unknown")

    def test_random_host_fallback_fails_closed(self):
        with patch.object(OWNER.uuid, "getnode", return_value=1 << 40), self.assertRaises(ValueError):
            OWNER.host_id()

    def test_linux_pid_namespace_is_part_of_identity(self):
        with (
            patch.object(OWNER.sys, "platform", "linux"),
            patch.object(OWNER.Path, "read_text", return_value="boot-one"),
            patch.object(OWNER.os, "readlink", return_value="pid:[100]"),
        ):
            identity = OWNER.capture(os.getpid())
            with patch.object(OWNER.os, "readlink", return_value="pid:[200]"):
                self.assertEqual(OWNER.observe(identity)["state"], "unknown")
            with patch.object(OWNER.Path, "read_text", return_value="boot-two"):
                self.assertEqual(OWNER.observe(identity)["state"], "unknown")


if __name__ == "__main__":
    unittest.main()
