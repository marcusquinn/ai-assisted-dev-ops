#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused admission invariants; no network or production state access."""

import importlib.util
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from gh_transport_budget import Budget, Deferred, scope_key  # noqa: E402

SPEC = importlib.util.spec_from_file_location("governor", SCRIPTS / "gh-transport-governor.py")
governor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(governor)


def headers(remaining=102, reset=2000, resource="core"):
    return {"x-ratelimit-remaining": str(remaining), "x-ratelimit-reset": str(reset),
            "x-ratelimit-resource": resource, "x-ratelimit-limit": "5000" if resource == "core" else "30"}


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp")))
        root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="gh-budget-test-", dir=root)
        self.directory = Path(self.temp.name)
        self.budget = Budget(self.directory, "owner-one")

    def tearDown(self):
        self.budget.close()
        self.temp.cleanup()

    def seed(self, remaining=102, reset=2000, resource="core"):
        token = self.budget.acquire(resource, now=1000)
        self.budget.finish(token, resource, headers(remaining, reset, resource), started=1000, now=1001)

    def test_atomic_reservations_protect_the_floor(self):
        self.seed()
        self.budget.acquire("core", now=1002)
        other = Budget(self.directory, "owner-one")
        try:
            other.acquire("core", now=1002)
            with self.assertRaises(Deferred):
                other.acquire("core", now=1002)
        finally:
            other.close()

    def test_stale_and_missing_state_allow_only_one_observation(self):
        self.budget.acquire("core", now=1000)
        with self.assertRaises(Deferred):
            self.budget.acquire("core", now=1001)

    def test_unknown_completion_does_not_deadlock_bootstrap(self):
        token = self.budget.acquire("core", now=1000)
        self.budget.finish(token, "core", {}, started=1000, now=1001)
        probe = self.budget.acquire("core", now=1002)
        self.budget.finish(probe, "core", headers(), started=1002, now=1003)
        self.assertEqual(self.budget.db.execute("SELECT COUNT(*) FROM reservation").fetchone()[0], 0)

    def test_late_header_never_increases_remaining(self):
        self.seed(150)
        token = self.budget.acquire("core", now=1002)
        self.budget.finish(token, "core", headers(4000), started=1002, now=1003)
        self.assertEqual(self.budget.db.execute("SELECT remaining FROM quota").fetchone()[0], 150)

    def test_reset_requires_a_new_response_not_a_new_allowance(self):
        self.seed(0, 1010)
        with self.assertRaises(Deferred):
            self.budget.acquire("core", now=1009)
        token = self.budget.acquire("core", now=1011)
        with self.assertRaises(Deferred):
            self.budget.acquire("core", now=1011)
        self.budget.finish(token, "core", headers(4999, 4600), started=1011, now=1012)
        self.budget.acquire("core", now=1013)

    def test_small_search_allowance_is_not_treated_as_core(self):
        self.seed(10, resource="search")
        self.budget.acquire("search", now=1002)

    def test_scope_and_resource_isolation(self):
        self.seed(0)
        other = Budget(self.directory, "owner-two")
        try:
            other.acquire("core", now=1002)
            self.budget.acquire("search", now=1002)
        finally:
            other.close()

    def test_token_rotation_does_not_invent_a_quota_owner(self):
        with patch.dict(os.environ, {"GH_TOKEN": "fixture-one"}):
            first = scope_key("github.com")
        with patch.dict(os.environ, {"GH_TOKEN": "fixture-two"}):
            self.assertEqual(first, scope_key("github.com"))

    def test_owner_configuration_cannot_split_one_credential_budget(self):
        self.seed(0)
        other = Budget(self.directory, "new-owner-name", "owner-one")
        try:
            with self.assertRaises(Deferred):
                other.acquire("core", now=1002)
            with self.assertRaises(Deferred):
                self.budget.acquire("core", now=1002)
        finally:
            other.close()

    def test_other_credential_response_cannot_erase_unknown_spend(self):
        self.seed()
        reservation = self.budget.acquire("core", now=1002)
        self.budget.finish(reservation, "core", {}, started=1002, now=1003)
        other = Budget(self.directory, "owner-one", "different-credential")
        try:
            probe = other.acquire("core", now=1004)
            other.finish(probe, "core", headers(), started=1004, now=1005)
            self.assertEqual(other.db.execute("SELECT COUNT(*) FROM reservation").fetchone()[0], 1)
        finally:
            other.close()

    def test_uncertain_execution_keeps_debt(self):
        self.seed()
        token = self.budget.acquire("core", now=1002)
        self.budget.finish(token, "core", {}, started=1002, now=1003)
        self.budget.acquire("core", now=1004)
        with self.assertRaises(Deferred):
            self.budget.acquire("core", now=1004)

    def test_unsupported_cached_and_opaque_shapes_remain_native(self):
        for args in (["api", "graphql"], ["api", "rate_limit"],
                     ["api", "user", "--cache", "1h"],
                     ["api", "user", "--paginate"],
                     ["api", "user", "-H", "X-Gh-Cache-Ttl: 1h"],
                     ["api", "user", "-H", "Authorization: fixture"],
                     ["api", "user", "-X", "POST"],
                     ["api", "user", "-f", "value=one"],
                     ["api", "user", "--input", "/dev/fd/9"],
                     ["api", "user", "-X", "GET", "-F", "q=@/dev/fd/9"],
                     ["api", "//foreign.invalid/user"],
                     ["pr", "checks", "--watch"]):
            self.assertIsNone(governor.request_shape(args))

    def test_read_parameters_do_not_change_method_or_authority(self):
        with patch.dict(os.environ, {"GH_HOST": "github.com", "GH_DEBUG": ""}):
            self.assertIsNotNone(governor.request_shape(
                ["api", "repos/owner/repo/issues?since=2026-09-04T00:00:00Z"]
            ))
            self.assertIsNotNone(governor.request_shape(
                ["api", "user", "--method", "GET", "-f", "value=one"]
            ))

    def test_native_child_uses_the_hashed_credential_without_parent_export(self):
        with patch.dict(os.environ, {}, clear=True), patch(
            "gh_transport_budget.subprocess.check_output", return_value=b"fixture-credential\n"
        ):
            fingerprint, authenticated, environment = governor.credential_identity("fixture-gh", "github.com")
            self.assertTrue(authenticated and len(fingerprint) == 64)
            self.assertTrue(environment.get("GH_TOKEN") == "fixture-credential")
            self.assertNotIn("GH_TOKEN", os.environ)

    def test_header_split_preserves_binary_body(self):
        body = b"\x00body\r\nHTTP/1.1 body text\n"
        stream = io.BytesIO(b"HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 12\r\n\r\n" + body)
        status, values, offset = governor.included_headers(stream)
        self.assertEqual(status, 200)
        self.assertEqual(values["x-ratelimit-remaining"], "12")
        stream.seek(offset)
        self.assertEqual(stream.read(), body)


if __name__ == "__main__":
    unittest.main()
