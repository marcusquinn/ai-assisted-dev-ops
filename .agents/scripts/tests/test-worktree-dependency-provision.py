#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fixture-only dependency provisioning and ownership regression tests."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 -- fixed offline fixture programs only.
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
GIT = shutil.which("git")
BASH = shutil.which("bash")
if not GIT or not BASH:
    raise RuntimeError("Git and Bash are required for fixture verification")
SPEC = importlib.util.spec_from_file_location("provision", SCRIPTS / "worktree-dependency-provision.py")
provision = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provision)


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        previous_umask = os.umask(0o022)
        self.addCleanup(os.umask, previous_umask)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.wt = self.root / "worktree"
        self.repo.mkdir()
        self.git(self.repo, "init", "-q")
        self.package = {"name": "fixture", "version": "1.0.0", "dependencies": {"example": "1.0.0"}}
        self.metadata = {"version": "1.0.0", "resolved": "fixture:example"}
        self.lock = {"lockfileVersion": 3, "packages": {"": self.package, "node_modules/example": self.metadata}}
        self.write(self.repo / "package.json", self.package)
        self.write(self.repo / "package-lock.json", self.lock)
        (self.repo / ".gitignore").write_text("node_modules/\n")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        self.git(self.repo, "worktree", "add", "-qb", "fixture-work", str(self.wt))
        self.modules = self.repo / "node_modules"
        self.write(self.modules / "example" / "package.json", {"name": "example", "version": "1.0.0"})
        (self.modules / "example" / "index.js").write_text("export const fixture = 1;\n")
        self.write(self.modules / ".package-lock.json", {"packages": {"node_modules/example": self.metadata}})

    @staticmethod
    def git(path, *args):
        return subprocess.check_output(  # nosec B603 -- resolved Git and fixture-owned argv, no shell.
            [GIT, "-C", str(path), *args], stderr=subprocess.DEVNULL, text=True).strip()

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def validate(self):
        return provision.identity(self.repo, self.wt, Path("."))

    def run_restore(self, owner="current", exact="true", root="auto", budget="67108864"):
        # All ownership and controller inputs are fixtures; never use the live registry.
        script = r'''
source "$1/worktree-helper-add.sh"
source "$1/pulse-dispatch-worker-launch.sh"
check_worktree_owner_snapshot() {
    if [[ "$OWNER" == current ]]; then printf '%s|fixture-session||31372|fixture-created|fixture-start\n' "$$";
    else printf '999999|foreign-session||31372|fixture-created|fixture-start\n'; fi
}
worktree_has_exact_owner_contract() { [[ "$EXACT" == true ]]; }
_dlw_node_modules_restore_acquire_lock() { return 0; }
_dlw_node_modules_restore_release_lock() { return 0; }
_dlw_restore_worktree_deps "$2" "$3"
'''
        env = {**os.environ, "OWNER": owner, "EXACT": exact,
               "LOGFILE": str(self.root / "restore.log"), "AIDEVOPS_WORKSPACE_DIR": str(self.root),
               "WORKTREE_NODE_MODULES_RESTORE_ROOT_ENABLED": root,
               "WORKTREE_NODE_MODULES_RESTORE_ENABLED": "1",
               "WORKTREE_NODE_MODULES_RESTORE_MAX_BYTES": budget}
        # Fixed shell program above; all parameters are isolated fixture paths.
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        subprocess.run(  # nosec B603 -- resolved Bash, fixed fixture program and fixture-only argv.
            [BASH, "-c", script, "fixture", str(SCRIPTS), str(self.wt), str(self.repo)],
                       env=env, check=True, capture_output=True, text=True, timeout=20)

    def test_bounded_read_and_repeat_preserve_checkpoint(self):
        self.assertEqual(self.validate()[0], self.modules)
        head = self.git(self.wt, "rev-parse", "HEAD")
        (self.wt / "checkpoint.txt").write_text("PR fixture #42; pending request perm-fixture")
        self.run_restore()
        copied = self.wt / "node_modules" / "example" / "index.js"
        self.assertEqual(copied.read_text(), "export const fixture = 1;\n")
        before = copied.stat().st_mtime_ns
        self.run_restore()
        self.assertEqual(copied.stat().st_mtime_ns, before)
        self.assertEqual(self.git(self.wt, "rev-parse", "HEAD"), head)
        self.assertIn("perm-fixture", (self.wt / "checkpoint.txt").read_text())
        self.assertFalse(list(self.wt.glob(".aidevops-deps-*")))

    def test_root_disabled(self):
        self.run_restore(root="0")
        self.assertFalse((self.wt / "node_modules").exists())

    def test_foreign_live_or_dead_owner(self):
        self.run_restore(owner="foreign")
        self.assertFalse((self.wt / "node_modules").exists())

    def test_recycled_owner_generation(self):
        self.run_restore(exact="false")
        self.assertFalse((self.wt / "node_modules").exists())

    def test_byte_budget(self):
        self.run_restore(budget="10")
        self.assertFalse((self.wt / "node_modules").exists())

    def test_copy_enforces_budget_without_preflight(self):
        stage = self.wt / "stage"
        stage.mkdir(mode=0o700)
        with self.assertRaises(provision.Rejected):
            provision.snapshot(self.modules, 10, 20000, stage)
        self.assertLessEqual(sum(p.stat().st_size for p in stage.rglob("*") if p.is_file()), 10)

    def test_entry_budget(self):
        with self.assertRaises(provision.Rejected):
            provision.snapshot(self.modules, 67108864, 1)

    def test_stale_package(self):
        self.write(self.wt / "package.json", {"name": "different"})
        with self.assertRaises(provision.Rejected):
            self.validate()

    def test_missing_package_identity(self):
        for parent in (self.repo, self.wt):
            self.write(parent / "package.json", {})
        with self.assertRaises(provision.Rejected):
            self.validate()

    def test_stale_lock(self):
        self.write(self.wt / "package-lock.json", {})
        with self.assertRaises(provision.Rejected):
            self.validate()

    def test_stale_installed_package(self):
        self.write(self.modules / "example" / "package.json", {"name": "example", "version": "2.0.0"})
        with self.assertRaises(provision.Rejected):
            self.validate()

    def test_missing_dependencies(self):
        shutil.rmtree(self.modules)
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    def test_missing_installed_lock(self):
        (self.modules / ".package-lock.json").unlink()
        with self.assertRaises(OSError):
            self.validate()

    def test_symlinked_manifest(self):
        (self.repo / "package.json").unlink()
        (self.repo / "package.json").symlink_to(self.wt / "package.json")
        with self.assertRaises(OSError):
            self.validate()

    def test_escaping_link_and_credentials(self):
        (self.modules / "escape").symlink_to(self.repo)
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())
        (self.modules / "escape").unlink()
        (self.modules / ".npmrc").write_text("fixture only")
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    def test_destination_symlink(self):
        (self.wt / "node_modules").symlink_to(self.modules)
        self.run_restore()
        self.assertTrue((self.wt / "node_modules").is_symlink())

    def test_source_not_shared_writable(self):
        (self.modules / "example" / "index.js").chmod(0o666)
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    def test_special_file(self):
        os.mkfifo(self.modules / "fifo")
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    def make_pnpm(self):
        lock_text = "lockfileVersion: '9.0'\npackages:\n  example@1.0.0:\n    resolution: {integrity: fixture}\n"
        for parent in (self.repo, self.wt):
            (parent / "package-lock.json").unlink()
            (parent / "pnpm-lock.yaml").write_text(lock_text)
        (self.modules / ".package-lock.json").unlink()
        store = self.modules / ".pnpm" / "example@1.0.0" / "node_modules"
        store.mkdir(parents=True)
        (self.modules / "example").rename(store / "example")
        (self.modules / "example").symlink_to(".pnpm/example@1.0.0/node_modules/example")
        (self.modules / ".pnpm" / "lock.yaml").write_text(lock_text)

    def test_pnpm_contained_links(self):
        self.make_pnpm()
        self.run_restore()
        copied = self.wt / "node_modules" / "example" / "index.js"
        self.assertTrue(copied.resolve().is_relative_to(self.wt))
        self.assertEqual(copied.read_text(), "export const fixture = 1;\n")

    def test_extra_unrecorded_package(self):
        self.write(self.modules / "extra" / "package.json", {"name": "extra", "version": "1.0.0"})
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    def test_manifestless_package_roots_and_files(self):
        for manager in ("npm", "pnpm"):
            if manager == "pnpm":
                self.make_pnpm()
            for extra in ("extra/index.js", "extra.js", "@extra.js", ".extra.js"):
                with self.subTest(manager=manager, extra=extra):
                    payload = self.modules / extra
                    payload.parent.mkdir(parents=True, exist_ok=True)
                    payload.write_text("fixture only")
                    self.run_restore()
                    self.assertFalse((self.wt / "node_modules").exists())
                    payload.unlink()
                    if payload.parent != self.modules:
                        payload.parent.rmdir()

    def test_missing_expected_installed_package(self):
        self.lock["packages"]["node_modules/missing"] = {"version": "1.0.0"}
        for parent in (self.repo, self.wt):
            self.write(parent / "package-lock.json", self.lock)
        with self.assertRaises(provision.Rejected):
            self.validate()

    def test_shared_worktree_root_rejected(self):
        self.wt.chmod(0o777)
        with self.assertRaises(provision.Rejected):
            self.validate()

    def test_malformed_lock_is_redacted(self):
        for parent in (self.repo, self.wt):
            self.write(parent / "package-lock.json", [])
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        result = subprocess.run(  # nosec B603 -- current interpreter, fixed helper and fixture-owned arguments.
            [sys.executable, str(SCRIPTS / "worktree-dependency-provision.py"),
                                 str(self.repo), str(self.wt), "."], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "dependency-provision-rejected\n")

    def test_atomic_promotion_does_not_replace_existing_directory(self):
        stage = self.wt / ".aidevops-deps-fixture" / "node_modules"
        stage.mkdir(parents=True, mode=0o700)
        stage.parent.chmod(0o700)
        destination = self.wt / "node_modules"
        destination.mkdir()
        with self.assertRaises(provision.Rejected):
            provision.publish(stage, self.wt, Path("."))
        self.assertTrue(stage.is_dir())
        self.assertTrue(destination.is_dir())


if __name__ == "__main__":
    unittest.main()
