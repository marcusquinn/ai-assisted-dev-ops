#!/usr/bin/env python3
"""Regression tests for atomic plaintext credential-store operations."""

from __future__ import annotations

import concurrent.futures
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "atomic-env-store.py"


class CredentialStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.config = Path(self.temporary.name) / ".config" / "aidevops"
        self.config.mkdir(parents=True, mode=0o700)
        os.chmod(self.config, 0o700)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_helper(self, *arguments: str, value: str = "") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(HELPER), *arguments, "--config-dir", str(self.config)],
            input=value,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_concurrent_distinct_upserts_preserve_every_key(self) -> None:
        target = self.config / "credentials.sh"

        def write(index: int) -> subprocess.CompletedProcess[str]:
            return self.run_helper(
                "upsert",
                "--target",
                str(target),
                "--name",
                f"CONCURRENT_KEY_{index}",
                value=f"value-{index}",
            )

        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
            results = list(executor.map(write, range(40)))

        self.assertTrue(all(result.returncode == 0 for result in results))
        content = target.read_text(encoding="utf-8")
        for index in range(40):
            self.assertEqual(content.count(f"export CONCURRENT_KEY_{index}="), 1)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        backups = list((self.config / "vault" / "recovery").glob("*.bak"))
        self.assertGreater(len(backups), 0)
        self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600 for path in backups))

    def test_migration_merges_then_replaces_root_with_loader(self) -> None:
        root = self.config / "credentials.sh"
        default = self.config / "tenants" / "default" / "credentials.sh"
        default.parent.mkdir(parents=True, mode=0o700)
        root.write_text('export ROOT_ONLY="one"\nexport SHARED="same"\n', encoding="utf-8")
        default.write_text('export DEFAULT_ONLY="two"\nexport SHARED="same"\n', encoding="utf-8")
        os.chmod(root, 0o600)
        os.chmod(default, 0o600)

        result = self.run_helper("migrate-default")

        self.assertEqual(result.returncode, 0, result.stderr)
        tenant_content = default.read_text(encoding="utf-8")
        self.assertIn('export ROOT_ONLY="one"', tenant_content)
        self.assertIn('export DEFAULT_ONLY="two"', tenant_content)
        loader = root.read_text(encoding="utf-8")
        self.assertIn('AIDEVOPS_ACTIVE_TENANT="default"', loader)
        self.assertNotIn("export ROOT_ONLY=", loader)

    def test_migration_conflict_fails_without_rewriting_sources(self) -> None:
        root = self.config / "credentials.sh"
        default = self.config / "tenants" / "default" / "credentials.sh"
        default.parent.mkdir(parents=True, mode=0o700)
        root_content = 'export SHARED="root"\n'
        default_content = 'export SHARED="default"\n'
        root.write_text(root_content, encoding="utf-8")
        default.write_text(default_content, encoding="utf-8")
        os.chmod(root, 0o600)
        os.chmod(default, 0o600)

        result = self.run_helper("migrate-default")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(root.read_text(encoding="utf-8"), root_content)
        self.assertEqual(default.read_text(encoding="utf-8"), default_content)

    def test_active_upserts_and_migration_share_one_transaction_lock(self) -> None:
        root = self.config / "credentials.sh"
        root.write_text('export SEED="seed"\n', encoding="utf-8")
        os.chmod(root, 0o600)

        def write(index: int) -> subprocess.CompletedProcess[str]:
            return self.run_helper(
                "upsert-active",
                "--name",
                f"MIGRATION_RACE_KEY_{index}",
                value=f"value-{index}",
            )

        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
            futures = [executor.submit(write, index) for index in range(30)]
            futures.append(executor.submit(self.run_helper, "migrate-default"))
            results = [future.result() for future in futures]

        self.assertTrue(all(result.returncode == 0 for result in results))
        default = self.config / "tenants" / "default" / "credentials.sh"
        content = default.read_text(encoding="utf-8")
        self.assertIn('export SEED="seed"', content)
        for index in range(30):
            self.assertEqual(content.count(f"export MIGRATION_RACE_KEY_{index}="), 1)
        self.assertIn("AIDEVOPS_ACTIVE_TENANT", root.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
