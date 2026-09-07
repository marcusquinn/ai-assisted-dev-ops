#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused admission invariants; no network or production state access."""

import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from gh_transport_budget import Budget, Deferred, quota_owner, reconcile_scope, scope_key  # noqa: E402

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

    def test_atomic_reservations_allow_final_point_but_not_overspend(self):
        self.seed(2)
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

    def test_positive_stale_balance_is_usable_with_serialized_observation(self):
        self.seed(100)
        probe = self.budget.acquire("core", now=1061)
        with self.assertRaises(Deferred):
            self.budget.acquire("core", now=1061)
        self.budget.finish(probe, "core", headers(99), started=1061, now=1062)
        self.budget.acquire("core", now=1063)

    def test_serialized_reserve_probe_repairs_same_credential_stale_balance(self):
        self.seed(100)
        probe = self.budget.acquire("core", now=1061)
        self.budget.finish(probe, "core", headers(4999), started=1061, now=1062)
        self.assertEqual(self.budget.db.execute("SELECT remaining FROM quota").fetchone()[0], 4999)
        self.budget.acquire("core", now=1063)

    def test_reserve_probe_does_not_mix_unresolved_credential_balances(self):
        self.seed(100)
        other = Budget(self.directory, "owner-one", "different-credential")
        try:
            probe = other.acquire("core", now=1061)
            other.finish(probe, "core", headers(4999), started=1061, now=1062)
            self.assertEqual(other.db.execute("SELECT remaining FROM quota").fetchone()[0], 100)
        finally:
            other.close()

    def test_configured_owner_recovers_shared_credential_balance(self):
        self.seed(100)
        other = Budget(self.directory, "owner-one", "different-credential", attributed=True)
        try:
            probe = other.acquire("core", now=1061)
            other.finish(probe, "core", headers(4999), started=1061, now=1062)
            self.assertEqual(other.db.execute("SELECT remaining FROM quota").fetchone()[0], 4999)
        finally:
            other.close()

    def test_configured_owner_alias_cannot_recover_before_reconciliation(self):
        self.seed(100)
        other = Budget(self.directory, "owner-one", "different-credential")
        configured = Budget(self.directory, "configured", "owner-one", attributed=True)
        try:
            self.assertFalse(configured.attributed)
            probe = configured.acquire("core", now=1061)
            configured.finish(probe, "core", headers(4999), started=1061, now=1062)
            self.assertEqual(configured.db.execute("SELECT remaining FROM quota").fetchone()[0], 100)
        finally:
            configured.close()
            other.close()

    def test_status_marks_legacy_configured_alias_for_reconciliation(self):
        from gh_transport_budget import admission_status
        self.seed(100)
        configured = Budget(self.directory, "configured", "owner-one", attributed=True)
        try:
            status = admission_status(self.directory, "configured", attributed=True)
            self.assertEqual(status["ambiguity"], "configured_owner_requires_reconciliation")
            self.assertEqual(status["reconcile_command"],
                             "python3 .agents/scripts/gh_transport_budget.py reconcile")
        finally:
            configured.close()

    def test_reconcile_requires_quiescence_without_mutating_state(self):
        self.seed(100)
        self.budget.acquire("core", now=1002)
        before = list(self.budget.db.execute("SELECT * FROM quota"))
        with self.assertRaisesRegex(Deferred, "no active or uncertain"):
            reconcile_scope(self.directory, "owner-one", "configured", now=1003)
        self.assertEqual(before, list(self.budget.db.execute("SELECT * FROM quota")))

    def test_reconcile_refuses_uncertain_reservation(self):
        self.seed(100)
        request = self.budget.acquire("core", now=1002)
        self.budget.finish(request, "core", {}, started=1002, now=1003)
        with self.assertRaisesRegex(Deferred, "no active or uncertain"):
            reconcile_scope(self.directory, "owner-one", "configured", now=1004)
        self.assertEqual(self.budget.db.execute(
            "SELECT uncertain FROM reservation"
        ).fetchone()[0], 1)

    def test_reconcile_preserves_cooldown_then_serializes_bootstrap(self):
        self.seed(100)
        self.budget.db.execute("UPDATE quota SET blocked_until=1100")
        self.budget.db.execute("INSERT INTO pacing VALUES(?,?,?,?,?)",
                               ("owner-one", "core", 2000, 1090, 100))
        result = reconcile_scope(self.directory, "owner-one", "configured", now=1061)
        self.assertEqual(result["state"], "reconciled")
        configured = Budget(self.directory, "configured", "owner-one", attributed=True)
        try:
            with self.assertRaisesRegex(Deferred, "server resource cooldown"):
                configured.acquire("core", now=1099)
            probe = configured.acquire("core", now=1100)
            with self.assertRaisesRegex(Deferred, "authoritative quota observation"):
                configured.acquire("core", now=1100)
            configured.finish(probe, "core", headers(4999, 2000), started=1100, now=1101)
            self.assertEqual(configured.db.execute(
                "SELECT remaining FROM quota WHERE scope='configured'"
            ).fetchone()[0], 4999)
            self.assertEqual(configured.db.execute("SELECT COUNT(*) FROM pacing").fetchone()[0], 0)
        finally:
            configured.close()

    def test_reconcile_reverses_alias_once_and_preserves_other_scope(self):
        self.seed(100)
        other = Budget(self.directory, "owner-one", "different-credential")
        independent = Budget(self.directory, "independent")
        try:
            independent_token = independent.acquire("core", now=1000)
            independent.finish(independent_token, "core", headers(77), started=1000, now=1001)
        finally:
            other.close()
            independent.close()
        result = reconcile_scope(self.directory, "owner-one", "configured", now=1061)
        self.assertEqual(result["bindings_rebound"], 2)
        self.assertEqual(reconcile_scope(
            self.directory, "owner-one", "configured", now=1062
        )["state"], "already_reconciled")
        with self.assertRaisesRegex(ValueError, "different configured owner"):
            reconcile_scope(self.directory, "owner-one", "different-owner", now=1063)
        self.assertEqual(self.budget._root("owner-one"), "configured")
        self.assertEqual(self.budget.db.execute(
            "SELECT remaining FROM quota WHERE scope='independent'"
        ).fetchone()[0], 77)

    def test_status_reports_unresolved_credential_ambiguity_without_identity(self):
        from gh_transport_budget import admission_status
        self.seed(100)
        other = Budget(self.directory, "owner-one", "different-credential")
        try:
            with patch("gh_transport_recovery.time.time", return_value=1002):
                status = admission_status(self.directory, "owner-one")
            self.assertEqual(status["ambiguity"], "unresolved_scope_has_multiple_credentials")
            self.assertEqual(status["bound_credentials"], 2)
            self.assertIn("gh_transport_budget.py reconcile", status["reconcile_command"])
            self.assertNotIn("different-credential", str(status))
        finally:
            other.close()

    def test_reserve_probe_never_spends_exhaustion_or_uncertain_last_point(self):
        self.seed(1)
        final = self.budget.acquire("core", now=1061)
        self.budget.finish(final, "core", {}, started=1061, now=1062)
        with self.assertRaises(Deferred):
            self.budget.acquire("core", now=1063)

    def test_failed_probe_keeps_debt_and_recovery_cadence(self):
        self.seed(100)
        probe = self.budget.acquire("core", now=1061)
        self.budget.finish(probe, "core", {}, started=1061, now=1062)
        self.assertEqual(self.budget.db.execute("SELECT COUNT(*) FROM reservation").fetchone()[0], 1)
        request = self.budget.acquire("core", now=1120)
        self.budget.finish(request, "core", headers(4999), started=1120, now=1121)
        self.assertEqual(self.budget.db.execute("SELECT remaining FROM quota").fetchone()[0], 100)

    def test_scope_and_resource_isolation(self):
        self.seed(0)
        other = Budget(self.directory, "owner-two")
        try:
            other.acquire("core", now=1002)
            self.budget.acquire("search", now=1002)
        finally:
            other.close()

    def test_alias_merge_preserves_probe_cadence_and_shared_owner_uncertainty(self):
        self.seed(100)
        other = Budget(self.directory, "owner-two", "credential-two")
        token = other.acquire("core", now=1000)
        other.finish(token, "core", headers(100), started=1000, now=1001)
        probe = other.acquire("core", now=1061)
        other.finish(probe, "core", {}, started=1061, now=1062)
        merged = Budget(self.directory, "owner-two", "owner-one")
        try:
            probe = merged.acquire("core", now=1121)
            merged.finish(probe, "core", headers(4999), started=1121, now=1122)
            self.assertEqual(merged.db.execute("SELECT remaining FROM quota").fetchone()[0], 100)
        finally:
            other.close()
            merged.close()

    def test_non_probe_with_matching_timestamp_cannot_restore_balance(self):
        self.seed(100)
        probe = self.budget.acquire("core", now=1061)
        self.budget.db.execute("UPDATE revalidation SET reservation_id='different-reservation'")
        self.budget.finish(probe, "core", headers(4999), started=1061, now=1062)
        self.assertEqual(self.budget.db.execute("SELECT remaining FROM quota").fetchone()[0], 100)

    def test_status_is_read_only_and_omits_identity(self):
        from gh_transport_budget import admission_status
        with patch("gh_transport_budget.time.time", return_value=1002):
            self.seed(100)
            before = self.budget.db.total_changes
            status = admission_status(self.directory, "owner-one")
            self.assertEqual(status["state"], "available")
            self.assertEqual(status["remaining"], 100)
            self.assertEqual(status["floor"], 0)
            self.assertEqual(before, self.budget.db.total_changes)
            self.assertNotIn("owner-one", str(status))
            self.assertEqual(admission_status(self.directory / "absent", "owner-one"), {"state": "unknown"})

    def test_token_rotation_does_not_invent_a_quota_owner(self):
        with patch.dict(os.environ, {"GH_TOKEN": "fixture-one"}):
            first = scope_key("github.com")
        with patch.dict(os.environ, {"GH_TOKEN": "fixture-two"}):
            self.assertEqual(first, scope_key("github.com"))

    def test_quota_owner_requires_explicit_valid_attribution(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(quota_owner(), ("unresolved", False))
        with patch.dict(os.environ, {"AIDEVOPS_GH_QUOTA_OWNER": "account-one"}):
            self.assertEqual(quota_owner(), ("account-one", True))
        with patch.dict(os.environ, {"AIDEVOPS_GH_QUOTA_OWNER": "x" * 257}):
            with self.assertRaisesRegex(ValueError, "invalid GitHub quota owner"):
                quota_owner()

    def test_reconcile_cli_bootstraps_configured_owner(self):
        root = Path(os.environ.get(
            "AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp")
        ))
        with tempfile.TemporaryDirectory(prefix="gh-budget-cli-", dir=root) as temp:
            directory = Path(temp)
            unresolved = scope_key("github.com", "unresolved")
            owner = scope_key("github.com", "account-one")
            first = Budget(directory, unresolved, "credential-one")
            second = Budget(directory, unresolved, "credential-two")
            try:
                token = first.acquire("core", now=1000)
                first.finish(token, "core", headers(100), started=1000, now=1001)
            finally:
                first.close()
                second.close()
            environment = {**os.environ, "AIDEVOPS_GH_QUOTA_OWNER": "account-one",
                           "AIDEVOPS_GH_TRANSPORT_STATE_DIR": str(directory)}
            result = subprocess.run(
                [sys.executable, str(SCRIPTS / "gh_transport_budget.py"), "reconcile"],
                check=True, capture_output=True, text=True, env=environment,
            )
            self.assertEqual(json.loads(result.stdout)["state"], "reconciled")
            configured = Budget(directory, owner, "credential-one", attributed=True)
            try:
                self.assertTrue(configured.attributed)
                configured.acquire("core", now=1061)
            finally:
                configured.close()

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
        self.seed(2)
        token = self.budget.acquire("core", now=1002)
        self.budget.finish(token, "core", {}, started=1002, now=1003)
        self.budget.acquire("core", now=1004)
        with self.assertRaises(Deferred):
            self.budget.acquire("core", now=1004)

    def test_healthy_concurrency_is_not_artificially_limited_to_four(self):
        self.seed(4999)
        for _ in range(100):
            self.budget.acquire("core", now=1002)
        with self.assertRaisesRegex(Deferred, "secondary ceiling"):
            self.budget.acquire("core", now=1002)
        with self.assertRaisesRegex(Deferred, "secondary ceiling"):
            self.budget.acquire("search", now=1002)

    def test_primary_pacing_uses_demand_and_releases_capacity_towards_reset(self):
        self.seed(100, reset=2000)
        self.budget.db.executemany("INSERT INTO admission_history VALUES(?,?,?)", [
            ("owner-one", "core", 1001 + i) for i in range(11)
        ])
        with self.assertRaisesRegex(Deferred, "observed demand") as result:
            self.budget.acquire("core", now=1012)
        self.assertGreater(result.exception.retry_at, 1012)
        # The same available quota is sufficient when reset is imminent.
        self.budget.db.execute("UPDATE quota SET reset=1013")
        self.budget.acquire("core", now=1012)

    def test_healthy_demand_does_not_force_sustainable_rate_when_unneeded(self):
        self.seed(4999)
        self.budget.db.executemany("INSERT INTO admission_history VALUES(?,?,?)", [
            ("owner-one", "core", 1001 + i) for i in range(11)
        ])
        self.budget.acquire("core", now=1012)

    def test_long_pacing_deadline_survives_history_expiry_and_process_reopen(self):
        self.seed(3)
        self.budget.db.executemany("INSERT INTO admission_history VALUES(?,?,?)", [
            ("owner-one", "core", 1001 + i) for i in range(11)
        ])
        with self.assertRaises(Deferred) as first:
            self.budget.acquire("core", now=1012)
        retry_at = first.exception.retry_at
        other = Budget(self.directory, "owner-one")
        try:
            with self.assertRaises(Deferred) as later:
                other.acquire("core", now=1100)
            self.assertEqual(later.exception.retry_at, retry_at)
            request = other.acquire("core", now=retry_at)
            other.finish(request, "core", headers(2), started=retry_at, now=retry_at + 0.1)
            with self.assertRaises(Deferred):
                other.acquire("core", now=retry_at + 1)
            # An actual increase in authoritative quota clears stale pacing.
            other.db.execute("UPDATE quota SET remaining=4999")
            other.acquire("core", now=retry_at + 2)
        finally:
            other.close()

    def test_pacing_cannot_withhold_the_last_primary_point(self):
        self.seed(1)
        self.budget.db.execute("INSERT INTO pacing VALUES(?,?,?,?,?)", ("owner-one", "core", 2000, 1900, 2))
        self.budget.acquire("core", now=1002)

    def test_normal_read_queues_for_pacing_longer_than_two_seconds(self):
        budget = Mock()
        budget.acquire.side_effect = [Deferred("paced", retryable=True, retry_at=1004), "permit"]
        with patch.dict(os.environ, {"AIDEVOPS_GH_READ_TIMEOUT": "15"}), \
                patch.object(governor.time, "time", return_value=1000), \
                patch.object(governor.time, "sleep") as sleep:
            self.assertEqual(governor._acquire(budget, "core"), "permit")
            sleep.assert_called_once_with(4)
        self.assertEqual(budget.acquire.call_count, 2)

    def test_pacing_outside_read_deadline_defers_without_sleep_or_http(self):
        budget = Mock()
        budget.acquire.side_effect = Deferred("paced", retryable=True, retry_at=1060)
        with patch.dict(os.environ, {"AIDEVOPS_GH_READ_TIMEOUT": "15"}), \
                patch.object(governor.time, "time", return_value=1000), \
                patch.object(governor.time, "sleep") as sleep:
            with self.assertRaises(Deferred):
                governor._acquire(budget, "core")
            sleep.assert_not_called()
        self.assertEqual(budget.acquire.call_count, 1)

    def test_secondary_point_window_is_shared_but_primary_demand_is_not(self):
        self.seed(4999)
        self.budget.db.executemany("INSERT INTO admission_history VALUES(?,?,?)", [
            ("owner-one", "core", 1001) for _ in range(900)
        ])
        with self.assertRaisesRegex(Deferred, "secondary ceiling"):
            self.budget.acquire("search", now=1002)
        self.budget.acquire("search", now=1062)

    def test_retry_after_remains_binding_with_available_primary_quota(self):
        self.seed(4999)
        request = self.budget.acquire("core", now=1002)
        self.budget.finish(request, "core", {**headers(4998), "retry-after": "42"},
                           started=1002, now=1003)
        with self.assertRaisesRegex(Deferred, "server resource cooldown") as result:
            self.budget.acquire("core", now=1044)
        self.assertEqual(result.exception.retry_at, 1045)
        self.budget.acquire("core", now=1045)

    def test_search_final_point_is_not_a_permanent_reserve(self):
        self.seed(1, resource="search")
        self.budget.acquire("search", now=1002)
        with self.assertRaises(Deferred):
            self.budget.acquire("search", now=1002)

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
