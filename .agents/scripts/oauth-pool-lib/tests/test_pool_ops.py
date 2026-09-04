#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Characterisation tests for oauth-pool-lib/pool_ops.py.

These tests pin observable behaviour BEFORE the t2069 refactor split so that
the per-command file split + helper extraction can be verified to preserve
byte-for-byte semantics.

Strategy:
  - All commands run in a subprocess against ``pool_ops.py`` via
    ``python3 -m oauth_pool_lib.pool_ops <command>`` (the actual shell
    invocation pattern). This catches dispatch/regression issues end-to-end
    and works equally against the pre-refactor file and the post-refactor
    facade.
  - HTTP-bound commands (``refresh``, ``rotate``) are exercised on the
    *filter / fallback* branches that don't make network calls. The
    network-success branch is structurally identical to the test-only path
    because both go through ``_call_token_endpoint`` after refactor; the
    pre-refactor inline ``urlopen`` call is left unmocked because it short
    circuits on the "no candidates need refresh" branch chosen by these
    fixtures.
  - Determinism: every test creates an isolated tempdir for the pool /
    auth files; nothing touches the user's real OAuth state.

Run:
    python3 -m unittest discover -s .agents/scripts/oauth-pool-lib/tests
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
from io import BytesIO
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[3]
POOL_OPS_DIR = REPO_ROOT / "scripts" / "oauth-pool-lib"
POOL_OPS_PY = POOL_OPS_DIR / "pool_ops.py"

# Load the dispatcher once so its hyphenated-directory package alias is
# registered as ``oauth_pool_lib`` for direct unit tests of shared helpers.
import importlib.util

_POOL_OPS_SPEC = importlib.util.spec_from_file_location("oauth_pool_lib.pool_ops", POOL_OPS_PY)
assert _POOL_OPS_SPEC is not None
_POOL_OPS_MOD = importlib.util.module_from_spec(_POOL_OPS_SPEC)
assert _POOL_OPS_SPEC.loader is not None
_POOL_OPS_SPEC.loader.exec_module(_POOL_OPS_MOD)

from oauth_pool_lib import _common  # noqa: E402
from oauth_pool_lib import pool_ops_refresh  # noqa: E402
from oauth_pool_lib import pool_ops_rotate  # noqa: E402


def run_pool_ops(command: str, env: dict[str, str], stdin: str | None = None) -> subprocess.CompletedProcess[str]:
    """Invoke ``python3 pool_ops.py <command>`` like ``oauth-pool-helper.sh``."""
    full_env = os.environ.copy()
    full_env.update(env)
    return subprocess.run(
        [sys.executable, str(POOL_OPS_PY), command],
        input=stdin,
        env=full_env,
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2))
    os.chmod(path, 0o600)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text())


class PoolOpsTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.pool_path = self.tmp / "pool.json"
        self.auth_path = self.tmp / "auth.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()


# ---------------------------------------------------------------------------
# cmd_auto_clear (cyclomatic 19)
# ---------------------------------------------------------------------------


class AutoClearTests(PoolOpsTestCase):
    def test_clears_expired_rate_limited_account(self) -> None:
        past = int(time.time() * 1000) - 60_000
        write_json(
            self.pool_path,
            {
                "anthropic": [
                    {
                        "email": "a@example.com",
                        "status": "rate-limited",
                        "cooldownUntil": past,
                    }
                ]
            },
        )
        result = run_pool_ops("auto-clear", {"POOL_FILE_PATH": str(self.pool_path)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "CHANGED")
        pool = read_json(self.pool_path)
        acct = pool["anthropic"][0]
        self.assertEqual(acct["status"], "idle")
        self.assertEqual(acct["cooldownUntil"], 0)

    def test_no_changes_when_nothing_expired(self) -> None:
        future = int(time.time() * 1000) + 600_000
        write_json(
            self.pool_path,
            {
                "anthropic": [
                    {
                        "email": "a@example.com",
                        "status": "rate-limited",
                        "cooldownUntil": future,
                    }
                ]
            },
        )
        result = run_pool_ops("auto-clear", {"POOL_FILE_PATH": str(self.pool_path)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "UNCHANGED")
        pool = read_json(self.pool_path)
        self.assertEqual(pool["anthropic"][0]["cooldownUntil"], future)

    def test_skips_underscore_prefixed_keys(self) -> None:
        past = int(time.time() * 1000) - 1_000
        write_json(
            self.pool_path,
            {
                "_pending_anthropic": {"refresh": "x", "access": "y"},
                "anthropic": [
                    {
                        "email": "a@example.com",
                        "status": "rate-limited",
                        "cooldownUntil": past,
                    }
                ],
            },
        )
        result = run_pool_ops("auto-clear", {"POOL_FILE_PATH": str(self.pool_path)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "CHANGED")
        pool = read_json(self.pool_path)
        # _pending key untouched
        self.assertIn("_pending_anthropic", pool)
        self.assertEqual(pool["anthropic"][0]["status"], "idle")

    def test_does_not_clear_non_rate_limited_status(self) -> None:
        """Expired cooldown is still cleared, but status remains untouched if not rate-limited."""
        past = int(time.time() * 1000) - 1_000
        write_json(
            self.pool_path,
            {
                "anthropic": [
                    {
                        "email": "a@example.com",
                        "status": "auth-error",
                        "cooldownUntil": past,
                    }
                ]
            },
        )
        result = run_pool_ops("auto-clear", {"POOL_FILE_PATH": str(self.pool_path)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "CHANGED")
        pool = read_json(self.pool_path)
        # cooldown cleared, but status preserved
        self.assertEqual(pool["anthropic"][0]["cooldownUntil"], 0)
        self.assertEqual(pool["anthropic"][0]["status"], "auth-error")


# ---------------------------------------------------------------------------
# cmd_mark_failure (cyclomatic 23)
# ---------------------------------------------------------------------------


class MarkFailureTests(PoolOpsTestCase):
    def _make_pool(self, accounts: list[dict]) -> None:
        write_json(self.pool_path, {"anthropic": accounts})

    def _make_auth(self, provider_entry: dict) -> None:
        write_json(self.auth_path, {"anthropic": provider_entry})

    def test_marks_account_matched_by_access_token(self) -> None:
        self._make_pool(
            [
                {"email": "a@example.com", "access": "token_A", "lastUsed": "2026-01-01T00:00:00Z"},
                {"email": "b@example.com", "access": "token_B", "lastUsed": "2026-01-02T00:00:00Z"},
            ]
        )
        self._make_auth({"access": "token_A"})
        result = run_pool_ops(
            "mark-failure",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
                "REASON": "rate_limit",
                "RETRY_SECONDS": "60",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("OK:a@example.com:rate-limited:"))
        pool = read_json(self.pool_path)
        a = pool["anthropic"][0]
        self.assertEqual(a["status"], "rate-limited")
        self.assertGreater(a["cooldownUntil"], int(time.time() * 1000))

    def test_rate_limit_fallback_retry_seconds_remains_short(self) -> None:
        self._make_pool([{"email": "a@example.com", "access": "tok"}])
        self._make_auth({"access": "tok"})
        before = int(time.time() * 1000)
        result = run_pool_ops(
            "mark-failure",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
                "REASON": "rate_limit",
                "RETRY_SECONDS": "60",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        cooldown_delta = read_json(self.pool_path)["anthropic"][0]["cooldownUntil"] - before
        self.assertGreaterEqual(cooldown_delta, 55_000)
        self.assertLess(cooldown_delta, 70_000)

    def test_short_retry_after_is_preserved(self) -> None:
        self._make_pool([{"email": "a@example.com", "access": "tok"}])
        self._make_auth({"access": "tok"})
        before = int(time.time() * 1000)
        result = run_pool_ops(
            "mark-failure",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
                "REASON": "rate_limit",
                "RETRY_SECONDS": "120",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        cooldown_delta = read_json(self.pool_path)["anthropic"][0]["cooldownUntil"] - before
        self.assertGreaterEqual(cooldown_delta, 115_000)
        self.assertLess(cooldown_delta, 130_000)

    def test_over_max_rate_limit_retry_after_is_clamped(self) -> None:
        self._make_pool([{"email": "a@example.com", "access": "tok"}])
        self._make_auth({"access": "tok"})
        before = int(time.time() * 1000)
        result = run_pool_ops(
            "mark-failure",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
                "REASON": "rate_limit",
                "RETRY_SECONDS": str(2 * 24 * 60 * 60),
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        cooldown_delta = read_json(self.pool_path)["anthropic"][0]["cooldownUntil"] - before
        self.assertGreaterEqual(cooldown_delta, (6 * 60 * 60 - 5) * 1000)
        self.assertLess(cooldown_delta, (6 * 60 * 60 + 10) * 1000)

    def test_auth_error_cooldown_is_not_rate_limit_clamped(self) -> None:
        self._make_pool([{"email": "a@example.com", "access": "tok"}])
        self._make_auth({"access": "tok"})
        before = int(time.time() * 1000)
        result = run_pool_ops(
            "mark-failure",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
                "REASON": "auth_error",
                "RETRY_SECONDS": "3600",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        cooldown_delta = read_json(self.pool_path)["anthropic"][0]["cooldownUntil"] - before
        self.assertGreaterEqual(cooldown_delta, (60 * 60 - 5) * 1000)
        self.assertLess(cooldown_delta, (60 * 60 + 10) * 1000)

    def test_falls_back_to_openai_account_id(self) -> None:
        write_json(
            self.pool_path,
            {
                "openai": [
                    {"email": "x@example.com", "access": "stale_x", "accountId": "acct_X"},
                    {"email": "y@example.com", "access": "stale_y", "accountId": "acct_Y"},
                ]
            },
        )
        write_json(self.auth_path, {"openai": {"access": "totally_different", "accountId": "acct_Y"}})
        result = run_pool_ops(
            "mark-failure",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "openai",
                "REASON": "auth_error",
                "RETRY_SECONDS": "300",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("OK:y@example.com:auth-error:"))
        pool = read_json(self.pool_path)
        self.assertEqual(pool["openai"][1]["status"], "auth-error")
        self.assertEqual(pool["openai"][0].get("status", "unset"), "unset")

    def test_falls_back_to_most_recent_last_used(self) -> None:
        self._make_pool(
            [
                {"email": "old@example.com", "access": "tok_old", "lastUsed": "2026-01-01T00:00:00Z"},
                {"email": "new@example.com", "access": "tok_new", "lastUsed": "2026-04-01T00:00:00Z"},
            ]
        )
        self._make_auth({"access": "totally_unrelated"})
        result = run_pool_ops(
            "mark-failure",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
                "REASON": "rate_limit",
                "RETRY_SECONDS": "60",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("OK:new@example.com:rate-limited:"))

    def test_skip_when_no_accounts(self) -> None:
        write_json(self.pool_path, {"anthropic": []})
        write_json(self.auth_path, {"anthropic": {"access": "x"}})
        result = run_pool_ops(
            "mark-failure",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
                "REASON": "rate_limit",
                "RETRY_SECONDS": "60",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "SKIP:no_accounts")

    def test_provider_error_maps_to_rate_limited(self) -> None:
        self._make_pool([{"email": "a@example.com", "access": "tok"}])
        self._make_auth({"access": "tok"})
        result = run_pool_ops(
            "mark-failure",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
                "REASON": "provider_error",
                "RETRY_SECONDS": "120",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rate-limited", result.stdout)


# ---------------------------------------------------------------------------
# cmd_rotate (cyclomatic 31)
# ---------------------------------------------------------------------------


class RotateTests(PoolOpsTestCase):
    def test_errors_when_only_one_account(self) -> None:
        write_json(self.pool_path, {"anthropic": [{"email": "a@example.com", "access": "tok"}]})
        write_json(self.auth_path, {"anthropic": {"access": "tok"}})
        result = run_pool_ops(
            "rotate",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ERROR:need_accounts")

    def test_rotates_to_idle_account(self) -> None:
        future = int(time.time() * 1000) + 10 * 60_000
        write_json(
            self.pool_path,
            {
                "anthropic": [
                    {
                        "email": "a@example.com",
                        "access": "tok_A",
                        "refresh": "ref_A",
                        "expires": future,
                        "status": "active",
                        "lastUsed": "2026-04-01T00:00:00Z",
                    },
                    {
                        "email": "b@example.com",
                        "access": "tok_B",
                        "refresh": "ref_B",
                        "expires": future,
                        "status": "idle",
                        "lastUsed": "2026-04-02T00:00:00Z",
                    },
                ]
            },
        )
        write_json(self.auth_path, {"anthropic": {"type": "oauth", "access": "tok_A"}})
        result = run_pool_ops(
            "rotate",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.strip().splitlines()
        self.assertEqual(lines[0], "OK")
        self.assertEqual(lines[1], "a@example.com")
        self.assertEqual(lines[2], "b@example.com")
        auth = read_json(self.auth_path)
        self.assertEqual(auth["anthropic"]["access"], "tok_B")

    def test_tier2_when_all_rate_limited(self) -> None:
        now_ms = int(time.time() * 1000)
        soon_cd = now_ms + 30_000   # ~1 minute from now
        later_cd = now_ms + 600_000  # 10 minutes from now
        write_json(
            self.pool_path,
            {
                "anthropic": [
                    {
                        "email": "a@example.com",
                        "access": "tok_A",
                        "refresh": "ref_A",
                        "expires": now_ms + 60_000,
                        "status": "rate-limited",
                        "cooldownUntil": later_cd,
                        "lastUsed": "2026-04-01T00:00:00Z",
                    },
                    {
                        "email": "b@example.com",
                        "access": "tok_B",
                        "refresh": "ref_B",
                        "expires": now_ms + 60_000,
                        "status": "rate-limited",
                        "cooldownUntil": soon_cd,
                        "lastUsed": "2026-04-02T00:00:00Z",
                    },
                ]
            },
        )
        write_json(self.auth_path, {"anthropic": {"type": "oauth", "access": "tok_A"}})
        result = run_pool_ops(
            "rotate",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.strip().splitlines()
        self.assertTrue(lines[0].startswith("OK_COOLDOWN:"))
        # Tier-2 picks the account with the *shortest* cooldown remaining
        self.assertEqual(lines[2], "b@example.com")

    def test_priority_wins_over_last_used(self) -> None:
        future = int(time.time() * 1000) + 10 * 60_000
        write_json(
            self.pool_path,
            {
                "anthropic": [
                    {
                        "email": "a@example.com",
                        "access": "tok_A",
                        "refresh": "ref_A",
                        "expires": future,
                        "status": "active",
                        "lastUsed": "2026-01-01T00:00:00Z",
                    },
                    {
                        "email": "b@example.com",
                        "access": "tok_B",
                        "refresh": "ref_B",
                        "expires": future,
                        "status": "active",
                        "lastUsed": "2026-04-02T00:00:00Z",
                        "priority": 5,
                    },
                    {
                        "email": "c@example.com",
                        "access": "tok_C",
                        "refresh": "ref_C",
                        "expires": future,
                        "status": "active",
                        "lastUsed": "2026-04-03T00:00:00Z",
                    },
                ]
            },
        )
        write_json(self.auth_path, {"anthropic": {"type": "oauth", "access": "tok_A"}})
        result = run_pool_ops(
            "rotate",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.strip().splitlines()
        self.assertEqual(lines[2], "b@example.com")  # priority 5 wins


# ---------------------------------------------------------------------------
# cmd_refresh (cyclomatic 72) - filter branches only (no HTTP)
# ---------------------------------------------------------------------------


class RefreshTests(PoolOpsTestCase):
    def test_no_op_when_token_not_expiring(self) -> None:
        future = int(time.time() * 1000) + 6 * 3_600_000  # 6h out
        write_json(
            self.pool_path,
            {
                "anthropic": [
                    {
                        "email": "a@example.com",
                        "access": "tok_A",
                        "refresh": "ref_A",
                        "expires": future,
                    }
                ]
            },
        )
        write_json(self.auth_path, {"anthropic": {"access": "tok_A"}})
        result = run_pool_ops(
            "refresh",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
                "TARGET_EMAIL": "all",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "NONE")

    def test_no_endpoint_for_unknown_provider(self) -> None:
        write_json(self.pool_path, {"cursor": []})
        write_json(self.auth_path, {"cursor": {}})
        result = run_pool_ops(
            "refresh",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "cursor",
                "TARGET_EMAIL": "all",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ERROR:no_endpoint")

    def test_no_op_when_no_refresh_token(self) -> None:
        write_json(
            self.pool_path,
            {
                "anthropic": [
                    {
                        "email": "a@example.com",
                        "access": "tok_A",
                        "refresh": "",
                        "expires": 0,
                    }
                ]
            },
        )
        write_json(self.auth_path, {"anthropic": {"access": "tok_A"}})
        result = run_pool_ops(
            "refresh",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
                "TARGET_EMAIL": "all",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "NONE")

    def test_target_email_filter(self) -> None:
        future = int(time.time() * 1000) + 6 * 3_600_000
        write_json(
            self.pool_path,
            {
                "anthropic": [
                    {"email": "a@example.com", "access": "tA", "refresh": "rA", "expires": future},
                    {"email": "b@example.com", "access": "tB", "refresh": "rB", "expires": future},
                ]
            },
        )
        write_json(self.auth_path, {"anthropic": {"access": "tA"}})
        result = run_pool_ops(
            "refresh",
            {
                "POOL_FILE_PATH": str(self.pool_path),
                "AUTH_FILE_PATH": str(self.auth_path),
                "PROVIDER": "anthropic",
                "TARGET_EMAIL": "missing@example.com",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "NONE")

    def test_http_refresh_error_is_sanitized_and_actionable(self) -> None:
        error = urllib.error.HTTPError(
            url="https://auth.example.invalid/token",
            code=400,
            msg="Bad Request",
            hdrs={},
            fp=BytesIO(b'{"error":"invalid_grant","error_description":"do not log this"}'),
        )
        with mock.patch("urllib.request.urlopen", side_effect=error):
            result = _common.call_token_endpoint("https://auth.example.invalid/token", "client", "secret-refresh", "ua")

        self.assertEqual(_common.token_refresh_error_label(result), "auth_invalid_grant")
        self.assertNotIn("secret-refresh", json.dumps(result))
        self.assertNotIn("do not log this", json.dumps(result))

    def test_shared_lock_uses_private_directory_protocol(self) -> None:
        lock_path = self.tmp / "oauth-pool.json.lock"
        lock_path.touch()
        with lock_path.open("w") as lock_file:
            _common.acquire_lock(lock_file, timeout=1)
            lock_dir = Path(str(lock_path) + ".d")
            owner_path = lock_dir / "owner"
            owner = read_json(owner_path)

            self.assertEqual(owner["schema"], "aidevops.oauth-lock/v1")
            self.assertEqual(owner["pid"], os.getpid())
            self.assertTrue(owner["token"])
            self.assertEqual(stat.S_IMODE(lock_dir.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(owner_path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(lock_path.stat().st_mode), 0o600)

            _common.release_lock(lock_file)
            self.assertFalse(lock_dir.exists())

    def test_atomic_write_enforces_private_parent_and_file_modes(self) -> None:
        private_dir = self.tmp / "private"
        target = private_dir / "state.json"
        _common.atomic_write_json(str(target), {"status": "active"})

        self.assertEqual(read_json(target), {"status": "active"})
        self.assertEqual(stat.S_IMODE(private_dir.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)

    def test_unauthorized_refresh_error_is_sanitized(self) -> None:
        error = urllib.error.HTTPError(
            url="https://auth.example.invalid/token",
            code=401,
            msg="Unauthorized",
            hdrs={},
            fp=BytesIO(b'{"error":"server_changed_shape"}'),
        )
        with mock.patch("urllib.request.urlopen", side_effect=error):
            result = _common.call_token_endpoint("https://auth.example.invalid/token", "client", "secret-refresh", "ua")

        self.assertEqual(_common.token_refresh_error_label(result), "http_401")
        self.assertNotIn("secret-refresh", json.dumps(result))

    def test_successful_refresh_with_invalid_json_is_sanitized(self) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b"not-json"
        with mock.patch("urllib.request.urlopen", return_value=response):
            result = _common.call_token_endpoint("https://auth.example.invalid/token", "client", "secret-refresh", "ua")

        self.assertEqual(_common.token_refresh_error_label(result), "invalid_response")
        self.assertNotIn("secret-refresh", json.dumps(result))

    def test_successful_refresh_with_non_dict_json_is_sanitized(self) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b'[]'
        with mock.patch("urllib.request.urlopen", return_value=response):
            result = _common.call_token_endpoint("https://auth.example.invalid/token", "client", "secret-refresh", "ua")

        self.assertEqual(_common.token_refresh_error_label(result), "invalid_response")

    def test_successful_refresh_with_type_error_is_sanitized(self) -> None:
        response = mock.MagicMock()
        body = mock.MagicMock()
        body.decode.return_value = None
        response.__enter__.return_value.read.return_value = body
        with mock.patch("urllib.request.urlopen", return_value=response):
            result = _common.call_token_endpoint("https://auth.example.invalid/token", "client", "secret-refresh", "ua")

        self.assertEqual(_common.token_refresh_error_label(result), "invalid_response")
        self.assertNotIn("secret-refresh", json.dumps(result))

    def test_urlopen_type_error_is_not_reclassified_as_invalid_response(self) -> None:
        with mock.patch("urllib.request.urlopen", side_effect=TypeError("bad timeout")):
            with self.assertRaises(TypeError):
                _common.call_token_endpoint("https://auth.example.invalid/token", "client", "secret-refresh", "ua")

    def test_rotate_reports_invalid_refresh_response(self) -> None:
        account = {"email": "a@example.com", "access": "old", "refresh": "secret-refresh", "expires": 1}
        with mock.patch.object(pool_ops_rotate, "TOKEN_URLS", {"anthropic": "https://auth.example.invalid/token"}), \
            mock.patch.object(pool_ops_rotate, "CLIENT_IDS", {"anthropic": "client"}), \
            mock.patch.object(pool_ops_rotate, "call_token_endpoint", return_value={_common.TOKEN_REFRESH_ERROR_KEY: "invalid_response"}), \
            mock.patch("sys.stderr") as stderr:
            pool_ops_rotate._try_refresh_token(account, "anthropic", int(time.time() * 1000), "ua")

        self.assertEqual(stderr.write.call_args_list[0].args[0], "REFRESH_FAILED:invalid_response")
        self.assertEqual(account["access"], "old")

    def test_rotate_handles_none_refresh_response(self) -> None:
        account = {"email": "a@example.com", "access": "old", "refresh": "secret-refresh", "expires": 1}
        with mock.patch.object(pool_ops_rotate, "TOKEN_URLS", {"anthropic": "https://auth.example.invalid/token"}), \
            mock.patch.object(pool_ops_rotate, "CLIENT_IDS", {"anthropic": "client"}), \
            mock.patch.object(pool_ops_rotate, "call_token_endpoint", return_value=None), \
            mock.patch("sys.stderr") as stderr:
            pool_ops_rotate._try_refresh_token(account, "anthropic", int(time.time() * 1000), "ua")

        self.assertEqual(stderr.write.call_args_list[0].args[0], "REFRESH_FAILED")
        self.assertEqual(account["access"], "old")

    def test_refresh_account_reports_sanitized_http_failure(self) -> None:
        account = {"email": "a@example.com", "access": "old", "refresh": "secret-refresh", "expires": 1}
        ctx = pool_ops_refresh._RefreshContext("https://auth.example.invalid/token", "client", "ua", "all")
        with mock.patch.object(pool_ops_refresh, "call_token_endpoint", return_value={_common.TOKEN_REFRESH_ERROR_KEY: "http_401"}):
            ok, label = pool_ops_refresh._refresh_one_account(account, ctx, int(time.time() * 1000))

        self.assertFalse(ok)
        self.assertEqual(label, "a@example.com(http_401)")
        self.assertNotIn("secret-refresh", label)

    def test_refresh_failure_sets_exponential_retry_backoff(self) -> None:
        now_ms = int(time.time() * 1000)
        account = {"email": "a@example.com", "access": "old", "refresh": "secret-refresh", "expires": 1}
        ctx = pool_ops_refresh._RefreshContext("https://auth.example.invalid/token", "client", "ua", "all")

        with mock.patch.object(pool_ops_refresh, "call_token_endpoint", return_value={_common.TOKEN_REFRESH_ERROR_KEY: "http_401"}):
            ok, _label = pool_ops_refresh._refresh_one_account(account, ctx, now_ms)

        self.assertFalse(ok)
        self.assertEqual(account["status"], "auth-error")
        self.assertEqual(account["authRefreshFailures"], 1)
        self.assertEqual(account["authRefreshLastFailureAt"], now_ms)
        self.assertEqual(account["cooldownUntil"], now_ms + 60_000)

        with mock.patch.object(pool_ops_refresh, "call_token_endpoint", return_value={_common.TOKEN_REFRESH_ERROR_KEY: "http_401"}):
            ok, _label = pool_ops_refresh._refresh_one_account(account, ctx, now_ms + 60_001)

        self.assertFalse(ok)
        self.assertEqual(account["authRefreshFailures"], 2)
        self.assertEqual(account["cooldownUntil"], now_ms + 60_001 + 120_000)

    def test_refresh_skips_auth_error_until_retry_backoff_expires(self) -> None:
        now_ms = int(time.time() * 1000)
        account = {
            "email": "a@example.com",
            "access": "old",
            "refresh": "secret-refresh",
            "expires": 1,
            "status": "auth-error",
            "cooldownUntil": now_ms + 60_000,
        }

        self.assertFalse(pool_ops_refresh._should_refresh_account(account, "all", now_ms))
        self.assertTrue(pool_ops_refresh._should_refresh_account(account, "all", now_ms + 60_001))

    def test_successful_refresh_clears_retry_backoff_state(self) -> None:
        now_ms = int(time.time() * 1000)
        account = {
            "email": "a@example.com",
            "access": "old",
            "refresh": "old-refresh",
            "expires": 1,
            "status": "auth-error",
            "cooldownUntil": now_ms,
            "authRefreshFailures": 3,
            "authRefreshLastFailureAt": now_ms - 1,
        }

        updated = pool_ops_refresh._apply_refresh_response(
            account,
            {"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600},
            now_ms,
        )

        self.assertTrue(updated)
        self.assertEqual(account["status"], "active")
        self.assertIsNone(account["cooldownUntil"])
        self.assertEqual(account["authRefreshFailures"], 0)
        self.assertIsNone(account["authRefreshLastFailureAt"])


# ---------------------------------------------------------------------------
# Smoke tests for non-high-complexity commands (one per module after split)
# ---------------------------------------------------------------------------


class SimpleCommandsSmokeTests(unittest.TestCase):
    def test_status_stats(self) -> None:
        pool = {
            "anthropic": [
                {"email": "a@example.com", "status": "active"},
                {"email": "b@example.com", "status": "rate-limited", "cooldownUntil": int(time.time() * 1000) + 60_000},
            ]
        }
        result = run_pool_ops(
            "status-stats",
            {"NOW_MS": str(int(time.time() * 1000)), "PROV": "anthropic"},
            stdin=json.dumps(pool),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Total accounts : 2", result.stdout)
        self.assertIn("anthropic pool", result.stdout)

    def test_list_accounts(self) -> None:
        pool = {"anthropic": [{"email": "a@example.com", "status": "active", "priority": 3}]}
        result = run_pool_ops(
            "list-accounts",
            {"PROVIDER": "anthropic"},
            stdin=json.dumps(pool),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("a@example.com", result.stdout)
        self.assertIn("priority:3", result.stdout)

    def test_extract_token_fields(self) -> None:
        result = run_pool_ops(
            "extract-token-fields",
            {},
            stdin=json.dumps({"access_token": "A", "refresh_token": "R", "expires_in": 7200}),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.strip().splitlines()
        self.assertEqual(lines, ["A", "R", "7200"])

    def test_extract_token_error_falls_back(self) -> None:
        result = run_pool_ops("extract-token-error", {}, stdin="not-json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "unknown")

    def test_normalize_cooldowns(self) -> None:
        past = int(time.time() * 1000) - 1_000
        pool = {"anthropic": [{"email": "a@example.com", "status": "rate-limited", "cooldownUntil": past}]}
        result = run_pool_ops("normalize-cooldowns", {"PROVIDER": "all"}, stdin=json.dumps(pool))
        self.assertEqual(result.returncode, 0, result.stderr)
        out = json.loads(result.stdout)
        self.assertEqual(out["updated"], 1)
        self.assertEqual(out["pool"]["anthropic"][0]["status"], "idle")

    def test_set_priority(self) -> None:
        pool = {"anthropic": [{"email": "a@example.com"}, {"email": "b@example.com", "priority": 1}]}
        result = run_pool_ops(
            "set-priority",
            {"PROVIDER": "anthropic", "EMAIL": "a@example.com", "PRIORITY": "5"},
            stdin=json.dumps(pool),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        out = json.loads(result.stdout)
        self.assertEqual(out["anthropic"][0]["priority"], 5)
        # b unchanged
        self.assertEqual(out["anthropic"][1]["priority"], 1)

    def test_set_priority_zero_clears(self) -> None:
        pool = {"anthropic": [{"email": "a@example.com", "priority": 7}]}
        result = run_pool_ops(
            "set-priority",
            {"PROVIDER": "anthropic", "EMAIL": "a@example.com", "PRIORITY": "0"},
            stdin=json.dumps(pool),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        out = json.loads(result.stdout)
        self.assertNotIn("priority", out["anthropic"][0])

    def test_remove_account_success(self) -> None:
        pool = {"anthropic": [{"email": "a@example.com"}, {"email": "b@example.com"}]}
        result = run_pool_ops(
            "remove-account",
            {"PROVIDER": "anthropic", "EMAIL": "a@example.com"},
            stdin=json.dumps(pool),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        out = json.loads(result.stdout)
        self.assertEqual(len(out["anthropic"]), 1)
        self.assertEqual(out["anthropic"][0]["email"], "b@example.com")

    def test_remove_account_not_found_returns_1(self) -> None:
        pool = {"anthropic": [{"email": "a@example.com"}]}
        result = run_pool_ops(
            "remove-account",
            {"PROVIDER": "anthropic", "EMAIL": "missing@example.com"},
            stdin=json.dumps(pool),
        )
        self.assertEqual(result.returncode, 1)

    def test_assign_pending_success(self) -> None:
        pool = {
            "anthropic": [{"email": "a@example.com", "access": "old"}],
            "_pending_anthropic": {"refresh": "newR", "access": "newA", "expires": 12345},
        }
        result = run_pool_ops(
            "assign-pending",
            {"PROVIDER": "anthropic", "EMAIL": "a@example.com"},
            stdin=json.dumps(pool),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        out = json.loads(result.stdout)
        self.assertEqual(out["anthropic"][0]["access"], "newA")
        self.assertEqual(out["anthropic"][0]["refresh"], "newR")
        self.assertNotIn("_pending_anthropic", out)

    def test_assign_pending_no_pending(self) -> None:
        pool = {"anthropic": [{"email": "a@example.com"}]}
        result = run_pool_ops(
            "assign-pending",
            {"PROVIDER": "anthropic", "EMAIL": "a@example.com"},
            stdin=json.dumps(pool),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ERROR:no_pending")

    def test_check_pending_none(self) -> None:
        result = run_pool_ops(
            "check-pending", {"PROVIDER": "anthropic"}, stdin=json.dumps({"anthropic": []})
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "NONE")

    def test_import_check_yes(self) -> None:
        pool = {"anthropic": [{"email": "a@example.com"}]}
        result = run_pool_ops("import-check", {"EMAIL": "a@example.com"}, stdin=json.dumps(pool))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "yes")

    def test_import_check_no(self) -> None:
        pool = {"anthropic": [{"email": "a@example.com"}]}
        result = run_pool_ops("import-check", {"EMAIL": "missing@example.com"}, stdin=json.dumps(pool))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "no")

    def test_check_expiry_negative(self) -> None:
        result = run_pool_ops("check-expiry", {"EXPIRES_IN": "-1000"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("EXPIRED", result.stdout)

    def test_check_expiry_minutes(self) -> None:
        result = run_pool_ops("check-expiry", {"EXPIRES_IN": str(45 * 60 * 1000)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("45m", result.stdout)

    def test_cursor_decode_jwt_invalid(self) -> None:
        result = run_pool_ops("cursor-decode-jwt", {"ACCESS": "not-a-jwt"})
        self.assertEqual(result.returncode, 0, result.stderr)
        # Single dotless string => parts < 2 => prints empty line then 0.
        # Don't .strip() — that would lose the leading empty line that callers parse.
        self.assertEqual(result.stdout, "\n0\n")

    def test_unknown_command_exits_1(self) -> None:
        result = run_pool_ops("not-a-real-command", {})
        self.assertEqual(result.returncode, 1)
        self.assertIn("Unknown command", result.stderr)

    def test_no_args_prints_usage(self) -> None:
        env = os.environ.copy()
        result = subprocess.run(
            [sys.executable, str(POOL_OPS_PY)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
