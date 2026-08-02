#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Regression tests for the shared canonical direct-write policy."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).parent.parent
HOOK_PATH = ROOT / ".agents" / "hooks" / "git_safety_guard.py"
POLICY_PATH = ROOT / ".agents" / "scripts" / "canonical-write-policy-helper.py"
REAL_GIT = "/usr/bin/git"
SCRIPTS_DIR = POLICY_PATH.parent

spec = importlib.util.spec_from_file_location("git_safety_guard", HOOK_PATH)
git_safety_guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(git_safety_guard)
sys.path.insert(0, str(SCRIPTS_DIR))
policy_spec = importlib.util.spec_from_file_location(
    "canonical_write_policy_helper", POLICY_PATH
)
canonical_write_policy = importlib.util.module_from_spec(policy_spec)
sys.modules[policy_spec.name] = canonical_write_policy
policy_spec.loader.exec_module(canonical_write_policy)


class CanonicalWritePolicyTests(unittest.TestCase):
    """Exercise canonical and linked contexts through the Claude adapter."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.repo = self.root / "repo"
        self.linked = self.root / "linked"
        self.repo.mkdir()
        self._git(self.repo, "init", "-q", "-b", "develop")
        self._git(self.repo, "config", "user.name", "Test")
        self._git(self.repo, "config", "user.email", "test@example.invalid")
        self._git(self.repo, "config", "commit.gpgsign", "false")
        (self.repo / "README.md").write_text("seed\n", encoding="utf-8")
        self._git(self.repo, "add", "README.md")
        self._git(self.repo, "commit", "-q", "-m", "seed")
        self._git(
            self.repo,
            "worktree",
            "add",
            "-q",
            "-b",
            "feature/test",
            str(self.linked),
        )

    @staticmethod
    def _git(cwd: Path, *args: str) -> str:
        return subprocess.run(  # nosec B603 -- fixed Git binary and test-owned argv
            [REAL_GIT, *args],
            cwd=cwd,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def _check(
        self,
        cwd: Path,
        target: Path | str = "",
        patch_text: str | None = None,
    ):
        with mock.patch.object(git_safety_guard.os, "getcwd", return_value=str(cwd)):
            return git_safety_guard._check_canonical_write(
                str(target), patch_text
            )

    def _create_repo_with_linked_worktree(
        self, root: Path, name: str
    ) -> tuple[Path, Path]:
        repo = root / f"{name}-repo"
        linked = root / f"{name}-linked"
        repo.mkdir()
        self._git(repo, "init", "-q", "-b", "main")
        self._git(repo, "config", "user.name", "Test")
        self._git(repo, "config", "user.email", "test@example.invalid")
        self._git(repo, "config", "commit.gpgsign", "false")
        (repo / "README.md").write_text(f"{name}\n", encoding="utf-8")
        self._git(repo, "add", "README.md")
        self._git(repo, "commit", "-q", "-m", f"{name} seed")
        self._git(
            repo,
            "worktree",
            "add",
            "-q",
            "-b",
            f"feature/{name}",
            str(linked),
        )
        return repo, linked

    def test_planning_files_are_denied_in_canonical_develop_checkout(self):
        for relative_path in ("README.md", "TODO.md", "todo/task.md"):
            with self.subTest(relative_path=relative_path):
                denial = self._check(self.repo, self.repo / relative_path)
                self.assertIsNotNone(denial)
                reason = denial["hookSpecificOutput"]["permissionDecisionReason"]
                self.assertIn("read-only session mirrors", reason)
                self.assertIn("create_or_use_linked_worktree", reason)

    def test_linked_worktree_write_is_allowed(self):
        self.assertIsNone(self._check(self.linked, self.linked / "new-file.md"))

    def test_canonical_context_allows_structurally_safe_targets(self):
        outside_target = self.root / "aidevops-issue-body.md"
        self.assertIsNone(self._check(self.repo, outside_target))
        self.assertIsNone(self._check(self.repo, self.linked / "new-file.md"))

    def test_cross_repository_linked_target_is_allowed_within_workspace(self):
        _, foreign_linked = self._create_repo_with_linked_worktree(
            self.root, "foreign"
        )

        with mock.patch.dict(
            canonical_write_policy.os.environ,
            {"AIDEVOPS_GIT_WORKSPACE_ROOT": str(self.root)},
        ):
            for cwd in (self.repo, self.linked):
                with self.subTest(cwd=cwd):
                    self.assertIsNone(
                        self._check(cwd, foreign_linked / "README.md")
                    )

    def test_cross_repository_linked_target_outside_workspace_is_denied(self):
        outside_temp = tempfile.TemporaryDirectory(
            prefix=f"{self.root.name}-sibling-", dir=self.root.parent
        )
        self.addCleanup(outside_temp.cleanup)
        outside_root = Path(outside_temp.name)
        _, foreign_linked = self._create_repo_with_linked_worktree(
            outside_root, "foreign"
        )

        with mock.patch.dict(
            canonical_write_policy.os.environ,
            {"AIDEVOPS_GIT_WORKSPACE_ROOT": str(self.root)},
        ):
            denial = self._check(self.linked, foreign_linked / "README.md")
            self.assertIsNotNone(denial)
            reason = denial["hookSpecificOutput"]["permissionDecisionReason"]
            self.assertIn("limited to the trusted Git workspace", reason)

            alias = self.root / "foreign-alias"
            alias.symlink_to(foreign_linked, target_is_directory=True)
            denial = self._check(self.linked, alias / "README.md")
            self.assertIsNotNone(denial)
            reason = denial["hookSpecificOutput"]["permissionDecisionReason"]
            self.assertIn("limited to the trusted Git workspace", reason)

    def test_context_outside_workspace_cannot_target_foreign_linked_worktree(self):
        outside_temp = tempfile.TemporaryDirectory()
        self.addCleanup(outside_temp.cleanup)
        outside_root = Path(outside_temp.name)
        _, outside_linked = self._create_repo_with_linked_worktree(
            outside_root, "outside"
        )

        with mock.patch.dict(
            canonical_write_policy.os.environ,
            {"AIDEVOPS_GIT_WORKSPACE_ROOT": str(self.root)},
        ):
            denial = self._check(outside_linked, self.linked / "README.md")
            self.assertIsNotNone(denial)
            reason = denial["hookSpecificOutput"]["permissionDecisionReason"]
            self.assertIn("limited to the trusted Git workspace", reason)

    def test_git_worktree_symlink_cannot_escape_to_outside_workspace(self):
        outside_temp = tempfile.TemporaryDirectory(
            prefix=f"{self.root.name}-outside-", dir=self.root.parent
        )
        self.addCleanup(outside_temp.cleanup)
        outside_root = Path(outside_temp.name)
        outside_file = outside_root / "outside.txt"
        outside_file.write_text("outside\n", encoding="utf-8")
        escaped_outside_file = outside_root.parent / f"{outside_root.name}-escaped.txt"
        escaped_outside_file.write_text("escaped\n", encoding="utf-8")
        self.addCleanup(escaped_outside_file.unlink, missing_ok=True)
        alias = self.linked / "outside-alias"
        alias.symlink_to(outside_root, target_is_directory=True)

        with mock.patch.dict(
            canonical_write_policy.os.environ,
            {"AIDEVOPS_GIT_WORKSPACE_ROOT": str(self.root)},
        ):
            denial = self._check(self.linked, alias / "outside.txt")
            self.assertIsNotNone(denial)
            reason = denial["hookSpecificOutput"]["permissionDecisionReason"]
            self.assertIn("symlinked write target escapes", reason)
            traversed_existing = alias / ".." / escaped_outside_file.name
            traversal_denial = self._check(self.linked, traversed_existing)
            self.assertIsNotNone(traversal_denial)
            traversal_reason = traversal_denial["hookSpecificOutput"][
                "permissionDecisionReason"
            ]
            self.assertIn("symlinked write target escapes", traversal_reason)
            traversed_missing = alias / ".." / f"{outside_root.name}-missing.txt"
            self.assertIsNotNone(self._check(self.linked, traversed_missing))
            self.assertIsNone(self._check(self.linked, outside_file))

    def test_linked_context_cannot_target_canonical_checkout(self):
        denial = self._check(self.linked, self.repo / "README.md")
        self.assertIsNotNone(denial)

    def test_outside_git_write_reports_outside_reason(self):
        decision = canonical_write_policy.check_write(
            str(self.root), str(self.root / "outside.txt")
        )
        self.assertEqual(decision["decision"], "allow")
        self.assertEqual(
            decision["reason"],
            "write target is outside canonical worktrees",
        )

    def test_empty_target_fails_closed(self):
        denial = self._check(self.repo)
        self.assertIsNotNone(denial)
        reason = denial["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertIn("write target is empty", reason)

    def test_outside_symlink_into_canonical_checkout_is_denied(self):
        alias = self.root / "canonical-alias"
        alias.symlink_to(self.repo, target_is_directory=True)
        denial = self._check(self.repo, alias / "README.md")
        self.assertIsNotNone(denial)
        reason = denial["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertIn("read-only session mirrors", reason)

    def test_missing_policy_helper_fails_closed(self):
        with mock.patch.object(
            git_safety_guard, "_resolve_policy_helper", return_value=""
        ):
            denial = self._check(self.linked, self.linked / "README.md")
        self.assertIn(
            "policy is unavailable",
            denial["hookSpecificOutput"]["permissionDecisionReason"],
        )

    def test_namespaced_direct_file_tools_are_classified(self):
        for tool_name in (
            "Edit",
            "edit_file",
            "write",
            "write_file",
            "functions.apply_patch",
            "namespace/Edit",
            "tools::apply-patch",
        ):
            with self.subTest(tool_name=tool_name):
                self.assertTrue(git_safety_guard._is_direct_file_tool(tool_name))
        self.assertFalse(git_safety_guard._is_direct_file_tool("functions.read"))

    def test_runtime_neutral_classifier_reports_structure(self):
        canonical = canonical_write_policy.classify_location(str(self.repo))
        linked = canonical_write_policy.classify_location(str(self.linked))
        self.assertEqual(canonical.classification, "canonical")
        self.assertEqual(linked.classification, "linked")

    def test_relative_git_identity_is_resolved_from_the_probed_checkout(self):
        responses = {
            ("rev-parse", "--is-inside-work-tree"): "true",
            ("rev-parse", "--show-toplevel"): ".",
            ("rev-parse", "--git-dir"): ".git",
            ("rev-parse", "--git-common-dir"): ".git",
            ("branch", "--show-current"): "develop",
        }

        def fake_git_output(_cwd: Path, *args: str) -> str:
            self.assertNotIn("--path-format=absolute", args)
            return responses.get(args, "")

        with mock.patch.object(
            canonical_write_policy, "_git_output", side_effect=fake_git_output
        ):
            result = canonical_write_policy.classify_location(str(self.repo))
        self.assertEqual(result.classification, "canonical")
        self.assertEqual(result.repo_root, str(self.repo.resolve()))

    def test_explicit_project_integration_branch_is_resolved(self):
        (self.repo / ".aidevops.json").write_text(
            json.dumps({"pr_base_branch": "develop"}), encoding="utf-8"
        )
        self._git(self.repo, "add", ".aidevops.json")
        self._git(self.repo, "commit", "-q", "-m", "configure integration branch")
        payload = canonical_write_policy.resolve_canonical_branch(str(self.repo))
        self.assertEqual(payload["branch"], "develop")
        self.assertEqual(payload["source"], "project-config-at-head")

    def test_untracked_project_config_cannot_choose_canonical_branch(self):
        (self.repo / ".aidevops.json").write_text(
            json.dumps({"pr_base_branch": "untrusted"}), encoding="utf-8"
        )
        with self.assertRaisesRegex(RuntimeError, "cannot be resolved"):
            canonical_write_policy.resolve_canonical_branch(str(self.repo))

    def test_non_object_policy_output_fails_closed(self):
        result = subprocess.CompletedProcess([], 0, stdout="null", stderr="")
        with mock.patch.object(
            git_safety_guard.subprocess, "run", return_value=result
        ):
            denial = self._check(self.linked, self.linked / "README.md")
        self.assertIn(
            "non-object payload",
            denial["hookSpecificOutput"]["permissionDecisionReason"],
        )

    def test_claude_adapter_passes_authoritative_runtime_identity(self):
        captured = {}

        def fake_policy(_helper, arguments, _input_text=None):
            captured["arguments"] = arguments
            return 0, {"decision": "allow", "rule_id": "command.default-allow"}

        with (
            mock.patch.object(
                git_safety_guard, "_resolve_policy_helper", return_value="/policy/helper"
            ),
            mock.patch.object(git_safety_guard.os, "getppid", return_value=4242),
            mock.patch.object(
                git_safety_guard,
                "_process_identity",
                return_value="runtime-generation-a",
            ),
            mock.patch.object(
                git_safety_guard, "_run_policy_helper", side_effect=fake_policy
            ),
        ):
            self.assertIsNone(git_safety_guard._check_command_policy("printf safe"))

        arguments = captured["arguments"]
        pid_index = arguments.index("--runtime-pid")
        identity_index = arguments.index("--runtime-process-identity")
        self.assertEqual(arguments[pid_index + 1], "4242")
        self.assertEqual(arguments[identity_index + 1], "runtime-generation-a")

    def test_apply_patch_targets_are_classified_individually(self):
        linked_patch = """*** Begin Patch
*** Add File: linked-only.md
+safe
*** End Patch
"""
        self.assertIsNone(self._check(self.linked, patch_text=linked_patch))
        absolute_linked_patch = f"""*** Begin Patch
*** Add File: {self.linked / 'absolute-linked.md'}
+safe
*** End Patch
"""
        self.assertIsNone(self._check(self.repo, patch_text=absolute_linked_patch))
        canonical_patch = f"""*** Begin Patch
*** Update File: {self.repo / 'README.md'}
@@
-seed
+unsafe
*** End Patch
"""
        denial = self._check(self.linked, patch_text=canonical_patch)
        self.assertIsNotNone(denial)
        self.assertIn(
            "read-only session mirrors",
            denial["hookSpecificOutput"]["permissionDecisionReason"],
        )

        outside_patch = f"""*** Begin Patch
*** Add File: {self.root / 'aidevops-issue-body.md'}
+safe
*** End Patch
"""
        self.assertIsNone(self._check(self.repo, patch_text=outside_patch))

        mixed_patch = f"""*** Begin Patch
*** Add File: {self.root / 'aidevops-issue-body.md'}
+safe
*** Update File: {self.repo / 'README.md'}
@@
-seed
+unsafe
*** End Patch
"""
        denial = self._check(self.repo, patch_text=mixed_patch)
        self.assertIsNotNone(denial)
        self.assertIn(
            "read-only session mirrors",
            denial["hookSpecificOutput"]["permissionDecisionReason"],
        )


if __name__ == "__main__":
    unittest.main()
